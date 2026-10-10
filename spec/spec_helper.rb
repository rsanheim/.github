# frozen_string_literal: true

require "rspec"
require "fileutils"
require_relative "../script/gem_release"

module ReleaseFixtures
  def with_event(name, data)
    ENV["GITHUB_EVENT_NAME"] = name
    ENV["GITHUB_REF"] = "refs/heads/main"
    Dir.mktmpdir do |directory|
      ENV["GITHUB_EVENT_PATH"] = File.join(directory, "event.json")
      File.write(ENV["GITHUB_EVENT_PATH"], JSON.generate(data))
      yield
    end
  end

  def in_directory
    Dir.mktmpdir do |directory|
      Dir.chdir(directory) { yield }
    end
  end

  def commit_fixture(message)
    release.command("git", "add", ".")
    release.command("git", "commit", "-qm", message)
    release.command("git", "rev-parse", "HEAD").strip
  end
end

RSpec.configure do |config|
  config.include ReleaseFixtures
  config.order = :random
  config.disable_monkey_patching!
  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.around do |example|
    original_environment = ENV.to_h
    ENV["GITHUB_SHA"] = "merged-sha"
    # Fixture repositories must not inherit signing, hooks, or user identity.
    ENV["GIT_CONFIG_GLOBAL"] = File::NULL
    ENV["GIT_CONFIG_NOSYSTEM"] = "1"
    example.run
  ensure
    ENV.replace(original_environment)
  end

  config.before do
    allow(Net::HTTP).to receive(:start).and_raise("Unexpected network request")
  end
end
