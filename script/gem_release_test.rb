# frozen_string_literal: true

require_relative "gem_release"
require "fileutils"

# Standalone harness: no test gems, and no network operations during tests.
class FakeRelease < GemRelease
  attr_accessor :responses, :versions, :commands, :remote
  attr_reader :outputs, :calls

  def initialize
    super({"gem" => "example"})
    @sha = "merged-sha"
    @responses = {}
    @versions = {"merged-sha" => "1.1.0", "previous-sha" => "1.0.0"}
    @commands = {}
    @calls = []
    @outputs = {}
  end

  def api(path, **options)
    @calls << [path, options]
    result = @responses.fetch(path) { raise "Unexpected API request: #{path}" }
    raise result if result.is_a?(Exception)
    result
  end

  def version(ref = @sha)
    @versions.fetch(ref)
  end

  def source(ref, path)
    raise "Unexpected source" unless ref == @sha && path == "CHANGELOG.md"
    "# Changes\n\n## [#{version}] - 2026-10-10\nReleased change\n\n## 1.0.0\nOld change"
  end

  def command(*args, **options)
    @calls << args
    result = @commands.fetch(args) { raise "Unexpected command: #{args}" }
    raise result if result.is_a?(Exception)
    result
  end

  def output(key, value)
    @outputs[key] = value
  end

  def registry
    @remote
  end
end

def assert(condition, message = "Assertion failed")
  raise message unless condition
end

def rejects(message)
  begin
    yield
  rescue => error
    assert(error.message.include?(message), "Expected #{message.inspect}, got #{error.message.inspect}")
    return
  end
  raise "Expected failure: #{message}"
end

def event(name, data)
  ENV["GITHUB_EVENT_NAME"] = name
  ENV["GITHUB_REF"] = "refs/heads/main"
  Dir.mktmpdir do |directory|
    ENV["GITHUB_EVENT_PATH"] = File.join(directory, "event.json")
    File.write(ENV["GITHUB_EVENT_PATH"], JSON.generate(data))
    yield
  end
end

runner = FakeRelease.new
assert(runner.validate("previous-sha", "merged-sha"))
assert(!runner.validate("merged-sha", "merged-sha"))
rejects("must not decrease") { runner.validate("merged-sha", "previous-sha") }
rejects("Missing nonempty") { runner.notes("## 1.1.0\n\n## 1.0.0\nOld", "1.1.0") }
assert(runner.notes("## [1.1.0] - date\nNew\n\n## 1.0.0\nOld", "1.1.0") == "New")
assert(runner.notes("## 1.1.0\nNew", "1.1.0") == "New")
rejects("Missing nonempty") { runner.notes("## 1.1.01\nWrong version", "1.1.0") }

pr = {"merged_at" => "2026-10-10", "merge_commit_sha" => "merged-sha", "base" => {"ref" => "main", "sha" => "previous-sha"}, "head" => {"sha" => "merged-sha"}}
event("pull_request", {"pull_request" => pr}) do
  runner.prepare
  assert(runner.calls.empty?, "PR validation must not call any APIs")
end
event("push", {"before" => "previous-sha"}) do
  path = "commits/merged-sha/pulls?per_page=100"
  runner.responses[path] = [pr.merge("merge_commit_sha" => "another-sha"), pr]
  runner.prepare
  assert(runner.outputs["release"] == "true")
  runner.responses[path] = [pr, pr]
  rejects("Ambiguous") { runner.prepare }
  runner.responses[path] = []
  rejects("merged PR") { runner.prepare }
  runner.versions["merged-sha"] = "1.0.0"
  runner.calls.clear
  runner.prepare
  assert(runner.outputs["release"] == "false" && runner.calls.empty?)
end

runner = FakeRelease.new
lookup = ["git", "ls-remote", "origin", "refs/tags/v1.1.0", "refs/tags/v1.1.0^{}"]
runner.commands[lookup] = "tag-object refs/tags/v1.1.0\nmerged-sha refs/tags/v1.1.0^{}"
runner.tag
assert(runner.calls.size == 1)
runner.commands[lookup] = "other-sha refs/tags/v1.1.0"
rejects("another commit") { runner.tag }
runner.commands[lookup] = ""
runner.commands[["git", "tag", "v1.1.0", "merged-sha"]] = ""
runner.commands[["git", "push", "origin", "refs/tags/v1.1.0"]] = RuntimeError.new("Push rejected")
rejects("Push rejected") { runner.tag }

Dir.mktmpdir do |directory|
  Dir.chdir(directory) do
    runner = FakeRelease.new
    assert(!runner.published?)
    Dir.mkdir("pkg")
    File.write("pkg/example-1.1.0.gem", "gem bytes")
    runner.remote = {"sha" => "different"}
    rejects("different bytes") { runner.published? }
    runner.remote = {"sha" => Digest::SHA256.hexdigest("gem bytes")}
    assert(runner.published?)
    runner.responses["releases?per_page=100"] = []
    runner.responses["releases"] = {"id" => 2}
    runner.finish
    assert(runner.calls.last[1][:data][:draft] == false)
    assert(runner.calls.last[1][:data][:body] == "Released change")
    assert(runner.calls.last[1][:data][:make_latest] == "legacy")
    runner.responses["releases?per_page=100"] = [{"tag_name" => "v1.1.0", "draft" => false}]
    runner.finish
    assert(runner.calls.last.first == "releases?per_page=100")
    runner.remote = nil
    rejects("not available") { runner.finish }
    runner.versions["merged-sha"] = "1.1.0.pre"
    File.write("pkg/example-1.1.0.pre.gem", "gem bytes")
    runner.remote = {"sha" => Digest::SHA256.hexdigest("gem bytes")}
    runner.responses["releases?per_page=100"] = []
    runner.finish
    assert(runner.calls.last[1][:data][:prerelease])
  end
end

# Real Git snapshots + real gemspec evaluation (including require_relative).
# Commit fixtures only to a disposable local repository; never create tags.
Dir.mktmpdir do |directory|
  Dir.chdir(directory) do
    runner = GemRelease.new({"gem" => "example"})
    runner.command("git", "init", "-q")
    runner.command("git", "config", "user.name", "Test")
    runner.command("git", "config", "user.email", "test@example.com")
    File.write("example.gemspec", 'Gem::Specification.new { |spec| spec.name = "example"; spec.version = "1.0.0" }')
    runner.command("git", "add", ".")
    runner.command("git", "commit", "-qm", "Literal version")
    baseline = runner.command("git", "rev-parse", "HEAD").strip
    assert(runner.version(baseline) == "1.0.0")
    FileUtils.mkdir_p("lib/example")
    File.write("lib/example/version.rb", 'module Example; VERSION = "1.1.0"; end')
    File.write("example.gemspec", 'require_relative "lib/example/version"; Gem::Specification.new { |spec| spec.name = "example"; spec.version = Example::VERSION; spec.summary = "Fixture"; spec.authors = ["Test"]; spec.files = ["lib/example/version.rb"] }')
    File.write("CHANGELOG.md", "## [1.1.0] - 2026-10-10\nNew version\n")
    runner.command("git", "add", ".")
    runner.command("git", "commit", "-qm", "Version constant")
    assert(runner.version("HEAD") == "1.1.0")
    assert(runner.validate(baseline, "HEAD"))
    ENV["SOURCE_DATE_EPOCH"] = runner.command("git", "log", "-1", "--format=%ct").strip
    runner.command("gem", "build", "example.gemspec", "--output", "first.gem")
    runner.command("gem", "build", "example.gemspec", "--output", "second.gem")
    assert(Digest::SHA256.file("first.gem").hexdigest == Digest::SHA256.file("second.gem").hexdigest)
    FileUtils.rm(["first.gem", "second.gem"])
    File.write("CHANGELOG.md", "## 1.1.0\n\n")
    runner.command("git", "add", ".")
    runner.command("git", "commit", "-qm", "Empty release notes")
    rejects("Missing nonempty") { runner.validate(baseline, "HEAD") }
  end
end

puts "Release automation tests passed (all network operations mocked)."
