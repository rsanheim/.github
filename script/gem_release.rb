# frozen_string_literal: true

require "open3"
require "rubygems"
require "securerandom"
require "tmpdir"

class GemRelease
  def initialize(gem, base, head)
    @gem = gem
    @base = base
    @head = head
  end

  def prepare
    previous = version(@base)
    current = version(@head)
    raise "Gem version must not decrease" if current < previous

    File.open(ENV.fetch("GITHUB_OUTPUT"), "a") do |output|
      output.puts "release=#{current > previous}"
      return if current == previous

      notes = changelog_notes(current)
      delimiter = SecureRandom.hex
      output.puts "version=#{current}", "notes<<#{delimiter}", notes, delimiter
    end
  end

  private

  def command(*args)
    stdout, stderr, status = Open3.capture3(*args)
    raise "#{args.first} failed: #{stderr}" unless status.success?
    stdout
  end

  def version(ref)
    # Evaluate the gemspec with its version file and other tracked source files.
    Dir.mktmpdir do |directory|
      archive = File.join(directory, "source.tar")
      command("git", "archive", "--output", archive, ref)
      command("tar", "-xf", archive, "-C", directory)
      loader = 'spec = Gem::Specification.load(ARGV.fetch(0)); abort "Cannot load gemspec" unless spec; abort "Unexpected gem name" unless spec.name == ARGV.fetch(1); puts spec.version'
      Gem::Version.new(command("ruby", "-C", directory, "-e", loader, "#{@gem}.gemspec", @gem).strip)
    end
  end

  def changelog_notes(version)
    text = command("git", "show", "#{@head}:CHANGELOG.md")
    # Accept ## 1.2.3 and ## [1.2.3] - date.
    section = text.split(/^##\s+/).drop(1).find do |part|
      part.lines.first.match?(/\A\[?#{Regexp.escape(version.to_s)}\]?(?:\s|$)/i)
    end
    body = section&.lines&.drop(1)&.join&.strip
    raise "Missing nonempty changelog section: #{version}" if !body || body.empty?
    body
  end
end

GemRelease.new(*ARGV).prepare if $PROGRAM_NAME == __FILE__
