# frozen_string_literal: true

require "json"

delegate_to ["release", "trigger"]

mixin "release-tools" do
  on_include do
    include :exec, e: true unless include? :exec
    include :fileutils unless include? :fileutils
    include :terminal unless include? :terminal
  end

  def verify_library_version vers, warn_only: false
    logger.info "Verifying library version..."
    require "#{context_directory}/lib/cloud_events/version.rb"
    lib_vers = ::CloudEvents::VERSION
    unless vers == lib_vers
      error "Tagged version #{vers.inspect} doesn't match library version #{lib_vers.inspect}.",
            "Modify lib/cloud_events/version.rb and set VERSION = #{vers.inspect}"
    end
    vers
  end

  def verify_changelog_content vers, warn_only: false
    logger.info "Verifying changelog content..."
    today = ::Time.now.strftime "%Y-%m-%d"
    entry = []
    state = :start
    path = ::File.join context_directory, "CHANGELOG.md"
    ::File.readlines(path).each do |line|
      case state
      when :start
        if line =~ /^### v#{::Regexp.escape(vers)} \/ \d\d\d\d-\d\d-\d\d\n$/
          entry << line
          state = :during
        elsif line =~ /^### /
          error "The first changelog entry isn't for version #{vers}.",
                "It should start with:",
                "### v#{vers} / #{today}",
                "But it actually starts with:",
                line,
                warn_only: warn_only
          return ""
        end
      when :during
        if line =~ /^### /
          state = :after
        else
          entry << line
        end
      end
    end
    if entry.empty?
      error "The changelog doesn't have any entries.",
            "The first changelog entry should start with:",
            "### v#{vers} / #{today}",
            warn_only: warn_only
    end
    entry.join
  end

  def verify_git_clean warn_only: false
    logger.info "Verifying git clean..."
    output = capture(["git", "status", "-s"]).strip
    unless output.empty?
      error "There are local git changes that are not committed.", warn_only: warn_only
    end
  end

  def verify_github_checks warn_only: false
    logger.info "Verifying GitHub checks..."
    ref = capture(["git", "rev-parse", "HEAD"]).strip
    result = exec ["gh", "api", "repos/cloudevents/sdk-ruby/commits/#{ref}/check-runs",
                   "-H", "Accept: application/vnd.github.antiope-preview+json"],
                  out: :capture, e: false
    unless result.success?
      error "Failed to obtain GitHub check results for #{ref}", warn_only: warn_only
      return
    end
    results = ::JSON.parse result.captured_out
    checks = results["check_runs"]
    error "No GitHub checks found for #{ref}", warn_only: warn_only if checks.empty?
    unless checks.size == results["total_count"]
      error "GitHub check count mismatch for #{ref}", warn_only: warn_only
    end
    checks.each do |check|
      name = check["name"]
      next unless name.start_with? "test"
      unless check["status"] == "completed"
        error "GitHub check #{name.inspect} is not complete", warn_only: warn_only
      end
      unless check["conclusion"] == "success"
        error "GitHub check #{name.inspect} was not successful", warn_only: warn_only
      end
    end
  end

  def build_gem version
    logger.info "Building cloud_events #{version} gem..."
    mkdir_p "pkg"
    exec ["gem", "build", "cloud_events.gemspec", "-o", "pkg/cloud_events-#{version}.gem"]
  end

  def push_gem version, dry_run: false
    logger.info "Pushing cloud_events #{version} gem..."
    built_file = "pkg/cloud_events-#{version}.gem"
    if dry_run
      error "#{built_file} didn't get built." unless ::File.file? built_file
      puts "SUCCESS: Mock release of cloud_events #{version}", :green, :bold
    else
      exec ["gem", "push", built_file]
      puts "SUCCESS: Released cloud_events #{version}", :green, :bold
    end
  end

  def build_docs version, dir
    logger.info "Building cloud_events #{version} docs..."
    rm_rf ".yardoc"
    rm_rf "doc"
    exec_separate_tool ["yardoc"]
    rm_rf "#{dir}/v#{version}"
    cp_r "doc", "#{dir}/v#{version}"
  end

  def set_default_docs version, dir
    logger.info "Changing default docs version to #{version}..."
    path = "#{dir}/404.html"
    content = ::IO.read path
    content.sub!(/version = "[\w\.]+";/, "version = \"#{version}\";")
    ::File.open path, "w" do |file|
      file.write content
    end
  end

  def push_docs version, dir, dry_run: false, git_remote: "origin"
    logger.info "Pushing docs to gh-pages..."
    cd dir do
      exec ["git", "add", "."]
      exec ["git", "commit", "-m", "Generate yardocs for version #{version}"]
      if dry_run
        puts "SUCCESS: Mock docs push for version #{version}.", :green, :bold
      else
        exec ["git", "push", git_remote, "gh-pages"]
        puts "SUCCESS: Pushed docs for version #{version}.", :green, :bold
      end
    end
  end

  def error message, *more_messages, warn_only: false
    puts message, :red, :bold
    more_messages.each { |m| puts(m) }
    exit 1 unless warn_only
  end
end
