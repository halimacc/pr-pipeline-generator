require 'yaml'

def load_pipeline(pipeline_file)
  # load the pipeline as a Hash 
  file = File.open(pipeline_file, 'r')
  pipeline_str = ''

  # special handling for parameters in pipeline
  file.each {|line|
    if line.include? '{{'
      line = line.sub('{{', '$').sub('}}', '$')
    end
    pipeline_str << line
  }

  file.close
  return YAML.load(pipeline_str);  
end

def extract_steps(steps)
  # initiallize
  result = []

  steps.each {|step|

    ['aggregate', 'do'].each {|k|
      if step.key?(k)
        result.concat(extract_steps(step[k]))
      end
    }

    ['on_success', 'on_failure', 'ensure', 'try'].each {|k|
      if step.key?(k)
        result.concat(extract_steps([step[k]]))
      end
    }

    result.push(step)    
  }

  return result
end

def replace_input_resource(pipeline, resource_name)
  # add pr resource type and resource
  pr_resource_type = {
    'name' => 'pull-request',
    'type' => 'docker-image',
    'source' => {
      'repository' => 'jtarchie/pr'
    }
  }

  pr_resource_name = 'bosh-cpi-pr'
  pr_resource = {
    'name' => pr_resource_name,
    'type' => 'pull-request',
    'source' => {
      'repo' => 'halimacc/bosh-azure-cpi-release',
      'access_token' => '$release_pr_access_token$',
      'private_key' => '$github_deployment_key__bosh-azure-cpi-release$',
      'every' => true
    }
  }
  
  if !pipeline.key?('resource_types')
    pipeline.store('resource_types', [])
  end
  pipeline['resource_types'].push(pr_resource_type)
  pipeline['resources'].push(pr_resource)

  # replace usage in jobs
  pipeline['jobs'].each {|job|
    steps = extract_steps(job['plan'])
    steps.each {|step|
      if step.key?('get')
        if step['get'] == resource_name || step.key?('resource') && step['resource'] == resource_name
          step['resource'] = pr_resource_name
          step['version'] = 'every'
        end
      end
    }
  }

  return pr_resource_name
end

def generate_notification_step(email_resource_name, subject, body, pr_resource_name, pr_resource_path, pr_status)
  step = {
    'do' => [{
      'task' => 'generate-email-content',
      'config' => {
        'platform' => 'linux',
        'image_resource' => {
          'type' => 'docker-image',
          'source' => {
            'repository' => 'ubuntu'
          }
        },
        'inputs' => [{'name' => pr_resource_path}],
        'outputs' => [{'name' => 'email-content'}],
        'run' => {
          'path' => 'sh',
          'args' => ['-c', "echo '#{subject}' > email-content/subject && echo '#{body}' > email-content/body"]
        }
      }
    }, {
      'put' => email_resource_name,
      'params' => {
        'subject' => 'email-content/subject',
        'body' => 'email-content/body'
      }
    }, {
      'put' => pr_resource_name,
      'params' => {
        'path' => pr_resource_path,
        'status' => pr_status
      }
    }]
  }
  return step
end

def wrap_job_on_failure(job, on_failure_step)
  plan = job['plan']
  rest_steps = plan[1 .. -1]
  plan[1] = {
    'do' => rest_steps,
    'on_failure' => on_failure_step
  }
  job['plan'] = plan[0 .. 1]
end

def add_notification_resource_and_steps(pipeline, key_resource_name, key_resource_path, entry_job_name, test_job_names)
  # add email resource
  email_resource_type = {
    'name' => 'email',
    'type' => 'docker-image',
    'source' => {
      'repository' => 'pcfseceng/email-resource'
    }
  }

  email_resource_name = 'email-notification'
  email_resource = {
    'name' => email_resource_name,
    'type' => 'email',
    'source' => {
      'smtp' => {
        'host' => '$email_smtp_host$',
        'port' => '$email_smtp_port$',
        'username' => '$email_smtp_username$',
        'password' => '$email_smtp_password$'
      },
      'from' => '$email_from$',
      'to' => ['t-chhe@microsoft.com']
    }
  }

  if !pipeline.key?('resource_types')
    pipeline.store('resource_types', [])
  end
  pipeline['resource_types'].push(email_resource_type)
  pipeline['resources'].push(email_resource)

  # add start notification for entry job
  entry_job = pipeline['jobs'].select {|job| job['name'] == entry_job_name}[0]
  build_start_step = generate_notification_step(email_resource_name, 'A new build has started', 'nobody', key_resource_name, key_resource_path, 'pending')
  entry_job['plan'].insert(1, build_start_step)

  # add on failure notification for entry job and test jobs
  wrap_job_on_failure(entry_job, generate_notification_step(email_resource_name, "Build failed at #{entry_job_name}", 'nobody', key_resource_name, key_resource_path, 'failure'))
  test_job_names.each{|job_name|
    test_job = pipeline['jobs'].select {|job| job['name'] == job_name}[0]
    wrap_job_on_failure(test_job, generate_notification_step(email_resource_name, "Build failed at #{job_name}", 'nobody', key_resource_name, key_resource_path, 'failure'))
  }

  # add a cleanup job for notify build result
  cleanup_job_name = 'cleanup-on-success'
  cleanup_job = {
    'name' => 'cleanup-on-success',
    'plan' => [{
        'get' => key_resource_name,
        'trigger' => true,
        'passed' => test_job_names
      },
      generate_notification_step(email_resource_name, 'Build passed', 'nobody', key_resource_name, key_resource_path, 'success')
    ]
  }

  pipeline['groups'][0]['jobs'].push(cleanup_job_name)
  pipeline['jobs'].push(cleanup_job)

  return cleanup_job_name
end

def add_pipeline_lock(pipeline, entry_job_name, exit_job_name)
  # add lock resource
  lock_resource_name = 'pipeline-lock'
  lock_resource = {
    'name' => lock_resource_name,
    'type' => 'pool',
    'source' => {
      'uri' => '$pipeline_lock_git_uri$',
      'branch' => '$pipeline_lock_branch$',
      'pool' => '$pipeline_lock_pool$',
      'private_key' => '$pipeline_lock_private_key$'
    }
  }

  pipeline['resources'].push(lock_resource)

  # insert lock step to the start of pipeline entry job
  entry_job = pipeline['jobs'].select {|job| job['name'] == entry_job_name}[0]
  entry_lock_step = {
    'put' => lock_resource_name,
    'params' => {
      'acquire' => true
    }
  }
  entry_job['plan'].insert(0, entry_lock_step)

  # insert lock step to the end of pipeline exit job
  exit_job = pipeline['jobs'].select {|job| job['name'] == exit_job_name}[0]
  exit_lock_step = {
    'do' => [{
      'get' => lock_resource_name
    }, {
      'put' => lock_resource_name,
      'params' => {
        'release' => lock_resource_name
      }
    }]
  }
  exit_job['plan'].push(exit_lock_step)

  # add a job to release lock manually
  release_lock_job_name = 'release-pipeline-lock'
  release_lock_job = {
    'name' => release_lock_job_name,
    'plan' => [{
        'get' => lock_resource_name
      }, {
        'put' => lock_resource_name,
        'params' => {
          'release' => lock_resource_name
        }
      }
    ]
  }

  pipeline['groups'][0]['jobs'].push(release_lock_job_name)
  pipeline['jobs'].push(release_lock_job)
end


#======================================================================================
# parameters
pipeline_file = 'pipeline.yml'
pr_pipeline_file = 'pr-pipeline.yml'
input_resource_name = 'bosh-cpi-release-in'
input_resource_path = 'bosh-cpi-release'
entry_job_name = 'build-candidate'
test_job_names = ['bats-ubuntu', 'lifecycle']

# main
pipeline = load_pipeline(pipeline_file)

replaced_resource_name = replace_input_resource(pipeline, input_resource_name)

cleanup_job_name = add_notification_resource_and_steps(pipeline, replaced_resource_name, input_resource_path, entry_job_name, test_job_names)

add_pipeline_lock(pipeline, entry_job_name, cleanup_job_name)

# write to file
File.open(pr_pipeline_file, 'w') { |f| f.write pipeline.to_yaml(line_width: -1).gsub('"$', '{{').gsub('$"', '}}') }





