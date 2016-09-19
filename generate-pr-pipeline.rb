require 'yaml'

# Params of new resources

# input pipeline file path
pipeline_file = 'pipeline.yml'

# output pipeline file path
pr_pipeline_file = 'pr-pipeline.yml'

# resource name of bosh-azure-cpi-release to replace
$input_resource_name = 'bosh-cpi-src-in'

# path name of the input resource in get
$input_resource_path = 'bosh-cpi-src'

# the repository of your bosh-azure-cpi-release
$pr_repo = 'halimacc/bosh-azure-cpi-release'

# concourse uri, used for email notification
$concourse_uri = 'http://localhost:8080'

# email notification list
$email_to_list = ['test@bosh.azure.cpi.com']
$email_from = 'bot@bosh.azure.cpi.com'

#==========================================================

$pr_resource_name = 'bosh-cpi-pr'
$entry_job_name = 'build-candidate'
$test_job_names = ['bats-ubuntu', 'lifecycle']
$cleanup_job_name = 'cleanup_on_success'
$email_resource_name = 'email-notification'

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

def replace_input_resource(pipeline)
  # add pr resource type and resource
  pr_resource_type = {
    'name' => 'pull-request',
    'type' => 'docker-image',
    'source' => {
      'repository' => 'jtarchie/pr'
    }
  }

  pr_resource = {
    'name' => $pr_resource_name,
    'type' => 'pull-request',
    'source' => {
      'repo' => $pr_repo,
      'access_token' => '$github_access_token$',
      'private_key' => '$github_deployment_key__bosh-azure-cpi-release$',
      #'every' => true
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
        if step['get'] == $input_resource_name || step.key?('resource') && step['resource'] == $input_resource_name
          step['resource'] = $pr_resource_name
          step['version'] = 'every'
          if job['name'] == $entry_job_name
            step['trigger'] = true
          end
        end
      end
    }
  }
end

def generate_notification_step(email_body, pr_status)
  email_subject = "Concourse notification on bosh-azure-cpi-release"
  email_output = 'email-content'
  step = {
    'do' => [{
      'task' => 'generate-email-content',
      'config' => {
        'platform' => 'linux',
        'image_resource' => {
          'type' => 'docker-image',
          'source' => {
            'repository' => 'jtarchie/pr'
          }
        },
        'inputs' => [{'name' => $input_resource_path}],
        'outputs' => [{'name' => email_output}],
        'run' => {
          'path' => 'sh',
          'args' => [
            '-c',
            "echo \"#{email_subject}\" > #{email_output}/subject "\
            "&& cd #{$input_resource_path} && export PR_ID=`git config --get pullrequest.id` "\
            "&& cd .. && echo \"Pull request #${PR_ID} : #{email_body}. View detail at #{$concourse_uri}/pipelines/pr-pipeline.\" > #{email_output}/body"
          ]
        }
      }
    }, {
      'put' => $email_resource_name,
      'params' => {
        'subject' => 'email-content/subject',
        'body' => 'email-content/body'
      }
    }, {
      'put' => $pr_resource_name,
      'params' => {
        'path' => $input_resource_path,
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

def add_notification_resource_and_steps(pipeline)
  # add email resource
  email_resource_type = {
    'name' => 'email',
    'type' => 'docker-image',
    'source' => {
      'repository' => 'pcfseceng/email-resource'
    }
  }

  email_resource = {
    'name' => $email_resource_name,
    'type' => 'email',
    'source' => {
      'smtp' => {
        'host' => '$email_smtp_host$',
        'port' => '$email_smtp_port$',
        'username' => '$email_smtp_username$',
        'password' => '$email_smtp_password$'
      },
      'from' => $email_from,
      'to' => $email_to_list
    }
  }

  if !pipeline.key?('resource_types')
    pipeline.store('resource_types', [])
  end
  pipeline['resource_types'].push(email_resource_type)
  pipeline['resources'].push(email_resource)

  # add start notification for entry job
  entry_job = pipeline['jobs'].select {|job| job['name'] == $entry_job_name}[0]
  build_start_step = generate_notification_step('Build started', 'pending')
  entry_job['plan'].insert(1, build_start_step)

  # add on failure notification for entry job and test jobs
  wrap_job_on_failure(entry_job, generate_notification_step("Build failed at job #{$entry_job_name}", 'failure'))
  $test_job_names.each{|job_name|
    test_job = pipeline['jobs'].select {|job| job['name'] == job_name}[0]
    wrap_job_on_failure(test_job, generate_notification_step("Build failed at job #{job_name}", 'failure'))
  }

  # add a cleanup job for notify build result
  cleanup_job = {
    'name' => $cleanup_job_name,
    'plan' => [{
        'get' => $input_resource_path,
        'resource' => $pr_resource_name,
        'trigger' => true,
        'passed' => $test_job_names
      },
      generate_notification_step('Build succeed', 'success')
    ]
  }

  pipeline['groups'][0]['jobs'].push($cleanup_job_name)
  pipeline['jobs'].push(cleanup_job)
end

def add_pipeline_lock(pipeline)
  # add lock resource
  lock_resource_name = 'pipeline-lock'
  lock_resource = {
    'name' => lock_resource_name,
    'type' => 'pool',
    'source' => {
      'uri' => '$pipeline_lock_git_uri$',
      'branch' => '$pipeline_lock_branch$',
      'pool' => 'pipeline',
      'private_key' => '$pipeline_lock_private_key$'
    }
  }

  pipeline['resources'].push(lock_resource)

  # insert lock step to the start of pipeline entry job
  entry_job = pipeline['jobs'].select {|job| job['name'] == $entry_job_name}[0]
  entry_lock_step = {
    'put' => lock_resource_name,
    'params' => {
      'acquire' => true
    }
  }
  entry_job['plan'].insert(0, entry_lock_step)

  # insert lock step to the end of pipeline exit job
  exit_job = pipeline['jobs'].select {|job| job['name'] == $cleanup_job_name}[0]
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


# main
pipeline = load_pipeline(pipeline_file)

replace_input_resource(pipeline)

add_notification_resource_and_steps(pipeline)

add_pipeline_lock(pipeline)

# write to file
File.open(pr_pipeline_file, 'w') { |f| f.write pipeline.to_yaml(line_width: -1).gsub('"$', '{{').gsub('$"', '}}') }





