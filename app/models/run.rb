class Run < ActiveRecord::Base
  include Sync::Actions
  belongs_to :owner
  belongs_to :scraper, inverse_of: :runs, touch: true
  has_many :log_lines
  has_one :metric
  has_many :connection_logs

  delegate :git_url, :full_name, to: :scraper
  delegate :current_revision_from_repo, to: :scraper, allow_nil: true
  delegate :utime, :stime, to: :metric

  def database
    Morph::Database.new(data_path)
  end

  def cpu_time
    utime + stime
  end

  def language
    Morph::Language.language(repo_path)
  end

  def finished_at=(time)
    write_attribute(:finished_at, time)
    update_wall_time
  end

  def update_wall_time
    if started_at && finished_at
      write_attribute(:wall_time, finished_at - started_at)
    end
  end

  def wall_time=(t)
    raise "Can't set wall_time directly"
  end

  def name
    if scraper
      scraper.name
    else
      # This run is using uploaded code and so is not associated with a scraper
      "run"
    end
  end

  def data_path
    "#{owner.data_root}/#{name}"
  end

  def repo_path
    "#{owner.repo_root}/#{name}"
  end

  def queued?
    queued_at && started_at.nil?
  end

  def running?
    started_at && finished_at.nil?
  end

  def finished?
    !!finished_at
  end

  def finished_with_errors?
    finished? && !finished_successfully?
  end

  def error_text
    log_lines.where(stream: "stderr").order(:number).map{|l| l.text}.join
  end

  def finished_successfully?
    finished? && status_code == 0
  end

  def self.time_output_filename
    "time.output"
  end

  def time_output_path
    File.join(data_path, Run.time_output_filename)
  end

  def docker_container_name
    "#{owner.to_param}_#{name}_#{id}"
  end

  def docker_image
    "openaustralia/morph-#{language}"
  end

  def git_revision_github_url
    "https://github.com/#{full_name}/commit/#{git_revision}"
  end

  def self.in_directory(directory)
    cwd = FileUtils.pwd
    FileUtils.cd(directory)
    yield
  ensure
    FileUtils.cd(cwd)
  end

  # Returns the filename of the tar
  # The directory needs to be an absolute path name
  def self.create_tar(directory, paths)
    tempfile = Tempfile.new('morph_tar')

    in_directory(directory) do
      begin
        tar = Archive::Tar::Minitar::Output.new(tempfile.path)
        paths.each do |entry|
          Archive::Tar::Minitar.pack_file(entry, tar)
        end
      ensure
        tar.close
      end
    end
    tempfile.path
  end

  # Relative paths to all the files in the given directory (recursive)
  # (except for anything below a directory starting with ".")
  def self.all_paths(directory)
    result = []
    Find.find(directory) do |path|
      if FileTest.directory?(path)
        if File.basename(path)[0] == ?.
          Find.prune
        end
      else
        result << Pathname.new(path).relative_path_from(Pathname.new(directory)).to_s
      end
    end
    result
  end

  def self.all_config_paths(directory)
    all_paths(directory) & ["Gemfile", "Gemfile.lock", "Procfile"]
  end

  def self.all_run_paths(directory)
    all_paths(directory) - all_config_paths(directory)
  end

  # A path to a tarfile that contains configuration type files
  # like Gemfile, requirements.txt, etc..
  # This comes from a whitelisted list
  # You must clean up this file yourself after you're finished with it
  def tar_config_files
    absolute_path = File.join(Rails.root, repo_path)
    Run.create_tar(absolute_path, Run.all_config_paths(absolute_path))
  end

  # A path to a tarfile that contains everything that isn't a configuration file
  # You must clean up this file yourself after you're finished with it
  def tar_run_files
    absolute_path = File.join(Rails.root, repo_path)
    Run.create_tar(absolute_path, Run.all_run_paths(absolute_path))
  end

  def go_with_logging
    go_with_logging_with_buildpacks
    #go_with_logging_original
  end

  def go_with_logging_original
    puts "Starting...\n"
    database.backup
    update_attributes(started_at: Time.now, git_revision: current_revision_from_repo)
    sync_update scraper if scraper
    FileUtils.mkdir_p data_path
    FileUtils.chmod 0777, data_path

    unless Morph::Language.language_supported?(language)
      supported_scraper_files = Morph::Language.languages_supported.map do |l|
        Morph::Language.language_to_scraper_filename(l)
      end.to_sentence(last_word_connector: ", or ")
      yield "stderr", "Can't find scraper code. Expected to find a file called " +
         supported_scraper_files + " in the root directory"
      update_attributes(status_code: 999, finished_at: Time.now)
      return
    end

    command = Metric.command(Morph::Language.scraper_command(language), Run.time_output_filename)
    status_code = Morph::DockerRunner.run(
      command: command,
      image_name: docker_image,
      container_name: docker_container_name,
      repo_path: repo_path,
      data_path: data_path,
      env_variables: scraper.variables.map{|v| [v.name, v.value]}
    ) do |on|
        on.log { |s,c| yield s, c}
        on.ip_address do |ip|
          # Store the ip address of the container for this run
          update_attributes(ip_address: ip)
        end
    end

    # Now collect and save the metrics
    metric = Metric.read_from_file(time_output_path)
    metric.update_attributes(run_id: self.id)

    update_attributes(status_code: status_code, finished_at: Time.now)
    # Update information about what changed in the database
    diffstat = Morph::Database.diffstat(database.sqlite_db_backup_path, database.sqlite_db_path)
    tables = diffstat[:tables][:counts]
    records = diffstat[:records][:counts]
    update_attributes(
      tables_added: tables[:added],
      tables_removed: tables[:removed],
      tables_changed: tables[:changed],
      tables_unchanged: tables[:unchanged],
      records_added: records[:added],
      records_removed: records[:removed],
      records_changed: records[:changed],
      records_unchanged: records[:unchanged]
    )
    Morph::Database.tidy_data_path(data_path)
    if scraper
      scraper.update_sqlite_db_size
      scraper.reload
      sync_update scraper
    end
  end

  def go_with_logging_with_buildpacks
    puts "Starting...\n"
    database.backup
    update_attributes(started_at: Time.now, git_revision: current_revision_from_repo)
    sync_update scraper if scraper
    FileUtils.mkdir_p data_path
    FileUtils.chmod 0777, data_path

    unless Morph::Language.language_supported?(language)
      supported_scraper_files = Morph::Language.languages_supported.map do |l|
        Morph::Language.language_to_scraper_filename(l)
      end.to_sentence(last_word_connector: ", or ")
      yield "stderr", "Can't find scraper code. Expected to find a file called " +
         supported_scraper_files + " in the root directory"
      update_attributes(status_code: 999, finished_at: Time.now)
      return
    end

    # Compile the container
    i = Docker::Image.get('progrium/buildstep')
    # Insert the configuration part of the application code into the container
    tar_path = tar_config_files
    hash = Digest::SHA2.hexdigest(File.read(tar_path))

    # Check if compiled image already exists
    begin
      i = Docker::Image.get("compiled_#{hash}")
      exists = true
    rescue Docker::Error::NotFoundError
      exists = false
    end

    unless exists
      # TODO insert_local produces a left-over container. Fix this.
      i2 = i.insert_local('localPath' => tar_path, 'outputPath' => '/app')
      i2.tag('repo' => "compiled_#{hash}")
      FileUtils.rm_f(tar_path)

      c = Morph::DockerRunner.run_no_cleanup(
        command: "/build/builder",
        user: "root",
        image_name: "compiled_#{hash}",
        env_variables: {CURL_TIMEOUT: 180}
      ) do |on|
        on.log { |s,c| yield s, c}
      end
      c.commit('repo' => "compiled_#{hash}")
      c.delete
    end

    # Insert the actual code into the container
    i = Docker::Image.get("compiled_#{hash}")
    tar_path = tar_run_files
    # TODO insert_local produces a left-over container. Fix this.
    i2 = i.insert_local('localPath' => tar_path, 'outputPath' => '/app')
    i2.tag('repo' => "compiled2_#{id}")
    FileUtils.rm_f(tar_path)

    command = Metric.command("/start scraper", "/data/" + Run.time_output_filename)
    status_code = Morph::DockerRunner.run(
      command: command,
      # TODO Need to run this as the user scraper again
      user: "root",
      image_name: "compiled2_#{id}",
      container_name: docker_container_name,
      data_path: data_path,
      env_variables: scraper.variables.map{|v| [v.name, v.value]}
    ) do |on|
        on.log { |s,c| yield s, c}
        on.ip_address do |ip|
          # Store the ip address of the container for this run
          update_attributes(ip_address: ip)
        end
    end

    i = Docker::Image.get("compiled2_#{id}")
    i.delete

    # Now collect and save the metrics
    metric = Metric.read_from_file(time_output_path)
    metric.update_attributes(run_id: self.id)

    update_attributes(status_code: status_code, finished_at: Time.now)
    # Update information about what changed in the database
    diffstat = Morph::Database.diffstat(database.sqlite_db_backup_path, database.sqlite_db_path)
    tables = diffstat[:tables][:counts]
    records = diffstat[:records][:counts]
    update_attributes(
      tables_added: tables[:added],
      tables_removed: tables[:removed],
      tables_changed: tables[:changed],
      tables_unchanged: tables[:unchanged],
      records_added: records[:added],
      records_removed: records[:removed],
      records_changed: records[:changed],
      records_unchanged: records[:unchanged]
    )
    Morph::Database.tidy_data_path(data_path)
    if scraper
      scraper.update_sqlite_db_size
      scraper.reload
      sync_update scraper
    end
  end

  def stop!
    Morph::DockerRunner.stop(docker_container_name)
  end

  def log(stream, text)
    puts "#{stream}: #{text}"
    number = log_lines.maximum(:number) || 0
    line = log_lines.create(stream: stream.to_s, text: text, number: (number + 1))
    sync_new line, scope: self
  end

  def go!
    go_with_logging do |s,c|
      log(s, c)
    end
  end

  # The main section of the scraper running that is run in the background
  def synch_and_go!
    # If this run belongs to a scraper that has just been deleted then don't do anything
    if scraper
      Morph::Github.synchronise_repo(repo_path, git_url)
      go!
    end
  end
end
