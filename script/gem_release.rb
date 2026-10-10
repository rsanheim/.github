# frozen_string_literal: true

require "json"
require "open3"
require "net/http"
require "digest"
require "rubygems"
require "tmpdir"

# Inputs come from the reusable workflow. `prepare` has read-only permissions;
# all other commands run only after a version-changing PR merges into main.
class GemRelease
  def initialize(config = JSON.parse(ENV.fetch("RELEASE_CONFIG")))
    @config = config
    @repo = ENV.fetch("GITHUB_REPOSITORY", "")
    @sha = ENV.fetch("GITHUB_SHA", "")
  end

  def command(*args, input: "")
    stdout, stderr, status = Open3.capture3(*args, stdin_data: input)
    raise "#{args.first} failed: #{stderr}" unless status.success?
    stdout
  end

  def api(path, method: "GET", data: nil, list: false)
    args = ["gh", "api", "repos/#{@repo}/#{path}", "--method", method]
    args += ["--paginate", "--slurp"] if list
    args += ["--input", "-"] if data
    result = JSON.parse(command(*args, input: data ? JSON.generate(data) : ""))
    list ? result.flatten(1) : result
  end

  def source(ref, path)
    command("git", "show", "#{ref}:#{path}")
  end

  def version(ref = @sha)
    # Load the effective gemspec in an isolated snapshot, so VERSION constants
    # and versions written directly in the gemspec behave identically.
    Dir.mktmpdir do |directory|
      archive = File.join(directory, "source.tar")
      command("git", "archive", "--output", archive, ref)
      command("tar", "-xf", archive, "-C", directory)
      loader = 'require "json"; spec = Gem::Specification.load(ARGV.fetch(0)); abort "Cannot load gemspec" unless spec; puts JSON.generate([spec.name, spec.version.to_s])'
      name, value = JSON.parse(command("ruby", "-C", directory, "-e", loader, @config.fetch("gemspec")))
      raise "Unexpected gem name: #{name}" unless name == @config.fetch("gem")
      value
    end
  end

  def notes(text, heading)
    # Accept ## 1.2.3 and ## [1.2.3] - date.
    section = text.split(/^##\s+/).drop(1).find do |part|
      part.lines.first.match?(/\A\[?#{Regexp.escape(heading)}\]?(?:\s|$)/i)
    end
    body = section&.lines&.drop(1)&.join&.strip
    raise "Missing nonempty changelog section: #{heading}" if !body || body.empty?
    body
  end

  def validate(base, head)
    previous = Gem::Version.new(version(base))
    current = Gem::Version.new(version(head))
    raise "Gem version must not decrease" if current < previous
    return false if current == previous
    notes(source(head, "CHANGELOG.md"), current.to_s)
    true
  end

  def output(key, value)
    File.open(ENV.fetch("GITHUB_OUTPUT"), "a") { |file| file.puts "#{key}=#{value}" }
  end

  def prepare
    event = JSON.parse(File.read(ENV.fetch("GITHUB_EVENT_PATH")))
    if ENV.fetch("GITHUB_EVENT_NAME") == "pull_request"
      pr = event.fetch("pull_request")
      validate(pr.fetch("base").fetch("sha"), pr.fetch("head").fetch("sha"))
      return
    end
    raise "Publication requires a push to main" unless ENV.fetch("GITHUB_REF") == "refs/heads/main"
    output("release", "false")
    return unless validate(event.fetch("before"), @sha)
    prs = api("commits/#{@sha}/pulls?per_page=100", list: true).select do |pr|
      pr["merged_at"] && pr["merge_commit_sha"] == @sha && pr.dig("base", "ref") == "main"
    end
    raise "Ambiguous merged PR for #{@sha}" if prs.size > 1
    raise "Version changes must arrive through a merged PR" if prs.empty?
    output("release", "true")
  end

  def releases
    api("releases?per_page=100", list: true)
  end

  def wait
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1800
    loop do
      statuses = api("commits/#{@sha}/statuses?per_page=100", list: true)
      # GitHub returns newest statuses first; an old success cannot mask failure.
      latest = statuses.each_with_object({}) { |status, result| result[status.fetch("context")] ||= status.fetch("state") }
      required = JSON.parse(@config.fetch("required-statuses"))
      raise "At least one external CI status is required" if required.empty?
      states = required.map { |context| latest[context] }
      raise "External CI failed for #{@sha}: #{latest}" if states.any? { |state| %w[failure error].include?(state) }
      return if states.all? { |state| state == "success" }
      raise "Timed out waiting for external CI on #{@sha}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      sleep 20
    end
  end

  def tag
    name = "v#{version}"
    refs = command("git", "ls-remote", "origin", "refs/tags/#{name}", "refs/tags/#{name}^{}").lines.map(&:split)
    if refs.any?
      target = refs.find { |_, ref| ref.end_with?("^{}") } || refs.first
      raise "Existing #{name} points to another commit" unless target.first == @sha
      return
    end
    command("git", "tag", name, @sha)
    command("git", "push", "origin", "refs/tags/#{name}")
  end

  def registry
    uri = URI("https://rubygems.org/api/v2/rubygems/#{@config.fetch("gem")}/versions/#{version}.json")
    response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) { |http| http.get(uri.request_uri) }
    return nil if response.code == "404"
    raise "RubyGems lookup failed: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
    JSON.parse(response.body)
  end

  def published?
    remote = registry
    return false unless remote
    checksum = Digest::SHA256.file("pkg/#{@config.fetch("gem")}-#{version}.gem").hexdigest
    raise "RubyGems already has different bytes for #{version}" unless remote.fetch("sha") == checksum
    true
  end

  def published
    output("published", published? ? "true" : "false")
  end

  def finish
    raise "Gem is not available on RubyGems" unless published?
    name = "v#{version}"
    existing = releases.find { |release| release["tag_name"] == name }
    return if existing && !existing["draft"]
    data = {tag_name: name, target_commitish: @sha, name: name, body: notes(source(@sha, "CHANGELOG.md"), version), draft: false, prerelease: Gem::Version.new(version).prerelease?, make_latest: "legacy"}
    api(existing ? "releases/#{existing.fetch("id")}" : "releases", method: existing ? "PATCH" : "POST", data: data)
  end
end

if $PROGRAM_NAME == __FILE__
  mode = ARGV.fetch(0)
  abort "Unknown release command" unless %w[prepare wait tag published finish].include?(mode)
  GemRelease.new.public_send(mode)
end
