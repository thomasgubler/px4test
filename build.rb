require 'sinatra'
require 'json'
require 'octokit'
require 'open3'
require 'fileutils'
require 'yaml'

config = begin
  YAML.load(File.open(".hans.yml"))
rescue ArgumentError => e
  puts "Could not parse .hans.yml: #{e.message}"
end

set :bind, '0.0.0.0'
set :environment, :production
# XXX webrick has issues in recent versions accepting non-localhost transfers
set :server, :thin
set :port, 4567

$access_token = config['github']['token']
$test_host = config['hostname']

$lf = '.lockfile'

def do_lock(board)
  # XXX put this into a function and check for a free worker
  # also requires to name directories after the free worker
  while File.file?(board)
    # Check if the lock file is really old, if yes, take our chances and wipe it
    if ((Time.now - File.stat(board).mtime).to_i > (60 * 10)) then
      unlock('boardname')
      break
    end

    # Keep waiting as long as the lock file exists
    sleep(1)
  end

  # This is the critical section - we might want to lock it
  # using a 2nd file, or something smarter and proper.
  # XXX for now, we just bet on timing - yay!
  FileUtils.touch($lf)
end

def do_unlock(board)
  # We're done - delete lock file
  FileUtils.rm_rf(board)
end

def do_work (command, error_message)

  Open3.popen2e(command) do |stdin, stdout_err, wait_thr|

    while line = stdout_err.gets
      puts "OUT> " + line
    end
    exit_status = wait_thr.value
    unless exit_status.success?
      do_unlock($lf)
      set_PR_Status $full_repo_name, $sha, 'failure', error_message
      abort "The command #{command} failed!"
    end
  end  
end  

    
def do_clone (srcdir, branch, html_url)
    puts "do_clone: " + branch
    system 'mkdir', '-p', srcdir
    Dir.chdir(srcdir) do
        #git clone <url> --branch <branch> --single-branch [<folder>]
        #result = `git clone --depth 500 #{html_url}.git --branch #{branch} --single-branch `
        #puts result
        do_work "git clone --depth 500 #{html_url}.git --branch #{branch} --single-branch", "Cloning repo failed."
        Dir.chdir("Firmware") do
            #result = `git submodule init && git submodule update`
            #puts result
            do_work "git submodule init", "GIT submodule init failed"
            do_work "git submodule update", "GIT submodule init failed"
        end
    end
end

def do_master_merge (srcdir, base_repo, base_branch)
    puts "do_merge of #{base_repo}/#{base_branch}"
    Dir.chdir(srcdir + "/Firmware") do
        do_work "git remote add base_repo #{base_repo}.git", "GIT adding upstream failed"
        do_work "git fetch base_repo", "GIT fetching upstream failed"
        do_work "git merge base_repo/#{base_branch} -m 'Merged #{base_repo}/#{base_branch} into test branch'", "Failed merging #{base_repo}/#{base_branch}"
    end
end
    
def do_build (srcdir)
    puts "Starting build"
    Dir.chdir(srcdir+"/Firmware") do    
        do_work  'BOARDS="px4fmu-v2 px4io-v2" make archives', "make archives failed"
        do_work  "make -j8 px4fmu-v2_test", "make px4fmu-v2_test failed"
    end
end    

def set_PR_Status (repo, sha, prstatus, description)

  puts "Access token: " + $access_token
  client = Octokit::Client.new(:access_token => $access_token)
  # XXX replace the URL below with the web server status details URL
  options = {
    "state" => prstatus,
    "target_url" => "http://px4.io/dev/unit_tests",
    "description" => description,
    "context" => "continuous-integration/hans-ci"
  };
  puts "Setting commit status on repo: " + repo + " sha: " + sha + " to: " + prstatus + " description: " + description
  res = client.create_status(repo, sha, prstatus, options)
  puts res
end    

def fork_hwtest (pr, srcdir, branch, url, full_repo_name, sha)
#Starts the hardware test in a subshell

pid = Process.fork
if pid.nil? then

  # Lock this board for operations
  do_lock($lf)

  # Clean up any mess left behind by a previous potential fail
  FileUtils.rm_rf(srcdir)

  # In child

  # Set relevant global variables for PR status
  $full_repo_name = full_repo_name
  $sha = sha

  tgit_start = Time.now
  do_clone srcdir, branch, url
  if !pr.nil?
    do_master_merge srcdir, pr['base']['repo']['html_url'], pr['base']['ref']
  end
  tgit_duration = Time.now - tgit_start
  tbuild_start = Time.now
  do_build srcdir
  tbuild_duration = Time.now - tbuild_start
  thw_start = Time.now
  system 'ruby hwtest.rb'
  puts "HW TEST RESULT:" + $?.exitstatus.to_s
  thw_duration = Time.now - thw_start

  timingstr = sprintf("git: %4.2fs build: %4.2fs hw: %4.2fs", tgit_duration, tbuild_duration, thw_duration)

  if ($?.exitstatus == 0) then
    set_PR_Status full_repo_name, sha, 'success', '#{$test_host}: Pixhawk HW test passed: ' + timingstr
  else
    set_PR_Status full_repo_name, sha, 'failure', '#{$test_host}: Pixhawk HW test FAILED: ' + timingstr
  end

  # Clean up by deleting the work directory
  FileUtils.rm_rf(srcdir)

  # Unlock this board
  do_unlock($lf)

else
  # In parent
  puts "Worker PID: " + pid.to_s
  Process.detach(pid)
end

end    














# ---------- Routing ------------
get '/' do
  'Hello unknown'
end
get '/payload' do
  "This URL is intended to be used with POST, not GET"
end
post '/payload' do
  body = JSON.parse(request.body.read)
  github_event = request.env['HTTP_X_GITHUB_EVENT']

  case github_event
  when 'ping'
        "Hello"    
  when 'pull_request'
    pr = body["pull_request"]
    number = body['number']
    puts pr['state']
    action = body['action']
    if (['opened', 'reopened'].include?(action))
      sha = pr['head']['sha']
      srcdir = sha
      full_name = pr['base']['repo']['full_name']
      ENV['srcdir'] = srcdir
      puts "Source directory: #{srcdir}"
      #Set environment vars for sub processes
      ENV['pushername'] = body['sender']['user']
      ENV['pusheremail'] = "lorenz@px4.io"
      branch = pr['head']['ref']
      url = pr['head']['repo']['html_url']
      puts "Adding to queue: Pull request: #{number} " + branch + " from "+ url
      set_PR_Status full_name, sha, 'pending', 'Running test on Pixhawk hardware..'
      fork_hwtest pr, srcdir, branch, url, full_name, sha
      'Pull request event queued for testing.'
    else
      puts 'Ignoring closing of pull request #' + String(number)
    end
  when 'push'
    branch = body['ref']

    if !(body['head_commit'].nil?) && body['head_commit'] != 'null'
      sha = body['head_commit']['id']
      srcdir = sha
      ENV['srcdir'] = srcdir
      puts "Source directory: #{srcdir}"
      #Set environment vars for sub processes
      ENV['pushername'] = body ['pusher']['name']
      ENV['pusheremail'] = body ['pusher']['email']
      a = branch.split('/')
      branch = a[a.count-1]           #last part is the bare branchname
      puts "Adding to queue: Branch: " + branch + " from "+ body['repository']['html_url']
      full_name = body['repository']['full_name']
      puts "Full name: " + full_name
      set_PR_Status full_name, sha, 'pending', 'Running test on Pixhawk hardware..'
      fork_hwtest nil, srcdir, branch, body['repository']['html_url'], full_name, sha
      'Push event queued for testing.'
    end
  when 'status'
    puts "Ignoring GH status event"
  when 'fork'
    puts 'Ignoring GH fork repo event'
  when 'delete'
    puts 'Ignoring GH delete branch event'
  when 'issue_comment'
    puts 'Ignoring comments'
  when 'issues'
    puts 'Ignoring issues'
  when 'pull_request_review_comment'
    puts 'Ignoring review comment'

  else
    puts "Unhandled request:"
    puts "Envelope: " + JSON.pretty_generate(request.env)
    puts "JSON: " + JSON.pretty_generate(body)
    puts "Unknown Event: " + github_event

  end
end
