# Pull-request Pipeline Generator

This repo is used to generate a pull-request version for ci pipeline of [bosh-azure-cpi-release](https://github.com/cloudfoundry-incubator/bosh-azure-cpi-release). To build a Concourse pipeline to run ci on pull requests, please follow below steps:

1. Prepare Resources
--------------------

In the first step, you need to prepare following resources for the pipeline.

#### 1.1 A Github access token
	
To enable Concourse CI to change Github Status of commits in a pull request like Travis CI, you need a Github access token for target repository with **repo:status** priviledge. See [create an access token](https://help.github.com/articles/creating-an-access-token-for-command-line-use/).

#### 1.2 A Git repository

To make the pipeline digest pull requests in serial, prepare a git repository as the lock pool for pipeline, with project structure as
```
.
pipeline
├── claimed
│   └── .gitkeep
└── unclaimed
	├── .gitkeep
	└── env
``` 
or fork from https://github.com/halimacc/pool-concourse-test.


#### 1.3 A SMTP email account

Used to send email notification, require username, password, SMTP server host and port.

2. Generate Pipeline
--------------------

Download `generate-pr-piprline.rb` script, and modify paramters at the top of the script, and run it.

Paramters:

| name | description |
|------|-------------|
| pipeline_file | path of original pipeline file of bosh-azure-cpi-release | 
| pr_pipeline_file | paht of pull request pipeline to generate |
| $input_resource_name | name of the git resource for bosh-azure-cpi-release |
| $input_resource_path | path of the git resource for bosh-azure-cpi-release in **get** steps |
| $pr_repo | bosh-azure-cpi-release in user/repo format |
| $concourse_uri | the uri for your Concourse |
| $email_to_list | email list to send notificaiton to |
| $email_from | name of email sender account |

3. Deploy Pipeline
------------------

before setting the pipeline, add below paramters to your original pipeline parameters files:

| name | value |
|------|-------|
| github_access_token | the token you created in step 1.1 |
| pipeline_lock_git_uri | uri of git repository of step 1.2, for example: git@github.com:user/repo |
| pipeline_lock_branch | branch of git repository of step 1.2 |
| pipeline_lock_private_key | ssh private key of git repository of step 1.2 |
| email_smtp_host | SMTP server host address of email account of step 1.3 |
| email_smtp_port | SMTP server port of email account of step 1.3 |
| email_smtp_username | username of email account of step 1.3 |
| email_smtp_password | password of email account of step 1.3 |

and then you can use fly CLI to deploy your pipeline.

