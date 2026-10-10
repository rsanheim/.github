# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe GemRelease do
  subject(:release) { described_class.new(config) }

  let(:config) { {"gem" => "example"} }
  let(:changelog) { "# Changes\n\n## [1.1.0] - 2026-10-10\nReleased change\n\n## 1.0.0\nOld change" }
  let(:merged_pr) do
    {"merged_at" => "2026-10-10", "merge_commit_sha" => "merged-sha",
     "base" => {"ref" => "main", "sha" => "previous-sha"}, "head" => {"sha" => "merged-sha"}}
  end

  before do
    allow(release).to receive(:api).and_raise("Unexpected API request")
    allow(release).to receive(:registry).and_raise("Unexpected registry request")
    allow(release).to receive(:command).and_raise("Unexpected command")
    allow(release).to receive(:version).with("previous-sha").and_return("1.0.0")
    allow(release).to receive(:version).with("merged-sha").and_return("1.1.0")
    allow(release).to receive(:version).with(no_args).and_return("1.1.0")
    allow(release).to receive(:source).with("merged-sha", "CHANGELOG.md").and_return(changelog)
    allow(release).to receive(:output)
  end

  describe "#validate" do
    it "requires release notes for a version increase" do
      expect(release.validate("previous-sha", "merged-sha")).to be(true)
    end

    it "skips release notes when the version does not change" do
      expect(release).not_to receive(:source)
      expect(release.validate("merged-sha", "merged-sha")).to be(false)
    end

    it "rejects a version decrease" do
      expect { release.validate("merged-sha", "previous-sha") }.to raise_error("Gem version must not decrease")
    end
  end

  describe "#notes" do
    it "extracts the matching bracketed heading and stops at the next version" do
      expect(release.notes(changelog, "1.1.0")).to eq("Released change")
    end

    it "accepts a plain version heading at the end of the file" do
      expect(release.notes("## 1.1.0\nNew", "1.1.0")).to eq("New")
    end

    it "rejects empty release notes" do
      expect { release.notes("## 1.1.0\n\n## 1.0.0\nOld", "1.1.0") }
        .to raise_error("Missing nonempty changelog section: 1.1.0")
    end

    it "rejects a heading that only matches the version prefix" do
      expect { release.notes("## 1.1.01\nWrong version", "1.1.0") }
        .to raise_error("Missing nonempty changelog section: 1.1.0")
    end
  end

  describe "#prepare" do
    it "validates pull requests without calling the API or requesting publication" do
      with_event("pull_request", {"pull_request" => merged_pr}) { release.prepare }
      expect(release).not_to have_received(:api)
      expect(release).not_to have_received(:output)
    end

    it "selects the merged PR for the exact pushed commit" do
      allow(release).to receive(:api).with("commits/merged-sha/pulls?per_page=100", list: true)
        .and_return([merged_pr.merge("merge_commit_sha" => "another-sha"), merged_pr])
      with_event("push", {"before" => "previous-sha"}) { release.prepare }
      expect(release).to have_received(:output).with("release", "true")
    end

    it "rejects multiple PRs matching the merged commit" do
      allow(release).to receive(:api).with("commits/merged-sha/pulls?per_page=100", list: true)
        .and_return([merged_pr, merged_pr])
      with_event("push", {"before" => "previous-sha"}) do
        expect { release.prepare }.to raise_error("Ambiguous merged PR for merged-sha")
      end
    end

    it "rejects a version increase without a merged PR" do
      allow(release).to receive(:api).with("commits/merged-sha/pulls?per_page=100", list: true).and_return([])
      with_event("push", {"before" => "previous-sha"}) do
        expect { release.prepare }.to raise_error("Version changes must arrive through a merged PR")
      end
    end

    it "does not accept an open PR or a PR targeting another branch" do
      allow(release).to receive(:api).with("commits/merged-sha/pulls?per_page=100", list: true)
        .and_return([merged_pr.merge("merged_at" => nil), merged_pr.merge("base" => {"ref" => "other"})])
      with_event("push", {"before" => "previous-sha"}) do
        expect { release.prepare }.to raise_error("Version changes must arrive through a merged PR")
      end
    end

    it "skips API requests and publication when a push does not change the version" do
      allow(release).to receive(:version).with("merged-sha").and_return("1.0.0")
      with_event("push", {"before" => "previous-sha"}) { release.prepare }
      expect(release).to have_received(:output).with("release", "false").once
      expect(release).not_to have_received(:api)
    end

    it "rejects publication from a branch other than main" do
      with_event("push", {"before" => "previous-sha"}) do
        ENV["GITHUB_REF"] = "refs/heads/other"
        expect { release.prepare }.to raise_error("Publication requires a push to main")
      end
    end
  end

  describe "#tag" do
    let(:lookup) { ["git", "ls-remote", "origin", "refs/tags/v1.1.0", "refs/tags/v1.1.0^{}"] }

    it "accepts an annotated tag whose peeled commit matches the merge" do
      expect(release).to receive(:command).with(*lookup)
        .and_return("tag-object refs/tags/v1.1.0\nmerged-sha refs/tags/v1.1.0^{}")
      release.tag
    end

    it "accepts a lightweight tag at the merged commit" do
      expect(release).to receive(:command).with(*lookup).and_return("merged-sha refs/tags/v1.1.0")
      release.tag
    end

    it "rejects an existing tag at another commit" do
      allow(release).to receive(:command).with(*lookup).and_return("other-sha refs/tags/v1.1.0")
      expect { release.tag }.to raise_error("Existing v1.1.0 points to another commit")
    end

    it "creates and pushes a missing tag using the exact merged commit" do
      expect(release).to receive(:command).with(*lookup).ordered.and_return("")
      expect(release).to receive(:command).with("git", "tag", "v1.1.0", "merged-sha").ordered.and_return("")
      expect(release).to receive(:command).with("git", "push", "origin", "refs/tags/v1.1.0").ordered.and_return("")
      release.tag
    end

    it "propagates a rejected tag push" do
      allow(release).to receive(:command).with(*lookup).and_return("")
      allow(release).to receive(:command).with("git", "tag", "v1.1.0", "merged-sha").and_return("")
      allow(release).to receive(:command).with("git", "push", "origin", "refs/tags/v1.1.0").and_raise("Push rejected")
      expect { release.tag }.to raise_error("Push rejected")
    end
  end

  describe "publication retries" do
    around do |example|
      in_directory do
        FileUtils.mkdir_p("pkg")
        File.write("pkg/example-1.1.0.gem", "gem bytes")
        example.run
      end
    end

    before do
      allow(release).to receive(:registry).and_return({"sha" => Digest::SHA256.hexdigest("gem bytes")})
    end

    it "reports an unpublished gem without requiring a local build" do
      allow(release).to receive(:registry).and_return(nil)
      FileUtils.rm("pkg/example-1.1.0.gem")
      expect(release.published?).to be(false)
    end

    it "accepts an already published gem with identical bytes" do
      expect(release.published?).to be(true)
    end

    it "rejects an already published gem with different bytes" do
      allow(release).to receive(:registry).and_return({"sha" => "different"})
      expect { release.published? }.to raise_error("RubyGems already has different bytes for 1.1.0")
    end

    [true, false].each do |published|
      it "writes the #{published} publication output" do
        allow(release).to receive(:published?).and_return(published)
        release.published
        expect(release).to have_received(:output).with("published", published.to_s)
      end
    end

    it "creates a public GitHub release with the matching changelog and commit" do
      allow(release).to receive(:api).with("releases?per_page=100", list: true).and_return([])
      expect(release).to receive(:api).with("releases", method: "POST", data: {
        tag_name: "v1.1.0", target_commitish: "merged-sha", name: "v1.1.0", body: "Released change",
        draft: false, prerelease: false, make_latest: "legacy"
      }).and_return({"id" => 2})
      release.finish
    end

    it "leaves an existing public GitHub release intact" do
      allow(release).to receive(:api).with("releases?per_page=100", list: true)
        .and_return([{"tag_name" => "v1.1.0", "draft" => false}])
      release.finish
      expect(release).to have_received(:api).once
    end

    it "publishes an existing draft instead of creating a duplicate" do
      allow(release).to receive(:api).with("releases?per_page=100", list: true)
        .and_return([{"id" => 2, "tag_name" => "v1.1.0", "draft" => true}])
      expect(release).to receive(:api).with("releases/2", method: "PATCH", data: hash_including(draft: false)).and_return({"id" => 2})
      release.finish
    end

    it "refuses a GitHub release when the gem is not published" do
      allow(release).to receive(:registry).and_return(nil)
      expect { release.finish }.to raise_error("Gem is not available on RubyGems")
      expect(release).not_to have_received(:api)
    end

    it "marks prerelease versions as GitHub prereleases" do
      allow(release).to receive(:version).with(no_args).and_return("1.1.0.pre")
      allow(release).to receive(:source).with("merged-sha", "CHANGELOG.md").and_return("## 1.1.0.pre\nPreview")
      File.write("pkg/example-1.1.0.pre.gem", "gem bytes")
      allow(release).to receive(:api).with("releases?per_page=100", list: true).and_return([])
      expect(release).to receive(:api).with("releases", method: "POST", data: hash_including(prerelease: true)).and_return({"id" => 2})
      release.finish
    end
  end

  describe "real Git snapshots and gem builds" do
    around do |example|
      in_directory { example.run }
    end

    before do
      allow(release).to receive(:command).and_call_original
      allow(release).to receive(:version).and_call_original
      allow(release).to receive(:source).and_call_original
      release.command("git", "init", "-q")
      release.command("git", "config", "user.name", "Test")
      release.command("git", "config", "user.email", "test@example.com")
      File.write("example.gemspec", 'Gem::Specification.new { |spec| spec.name = "example"; spec.version = "1.0.0" }')
      @baseline = commit_fixture("Literal version")
      FileUtils.mkdir_p("lib/example")
      File.write("lib/example/version.rb", 'module Example; VERSION = "1.1.0"; end')
      File.write("example.gemspec", 'require_relative "lib/example/version"; Gem::Specification.new { |spec| spec.name = "example"; spec.version = Example::VERSION; spec.summary = "Fixture"; spec.authors = ["Test"]; spec.files = ["lib/example/version.rb"] }')
      File.write("CHANGELOG.md", "## [1.1.0] - 2026-10-10\nNew version\n")
      commit_fixture("Version constant")
    end

    it "evaluates both literal versions and required version constants from their snapshots" do
      expect(release.version(@baseline)).to eq("1.0.0")
      expect(release.version("HEAD")).to eq("1.1.0")
      expect(release.validate(@baseline, "HEAD")).to be(true)
    end

    it "builds identical gem bytes with the merged commit timestamp" do
      ENV["SOURCE_DATE_EPOCH"] = release.command("git", "log", "-1", "--format=%ct").strip
      release.command("gem", "build", "example.gemspec", "--output", "first.gem")
      release.command("gem", "build", "example.gemspec", "--output", "second.gem")
      expect(Digest::SHA256.file("first.gem").hexdigest).to eq(Digest::SHA256.file("second.gem").hexdigest)
    end

    it "rejects empty release notes in a committed snapshot" do
      File.write("CHANGELOG.md", "## 1.1.0\n\n")
      commit_fixture("Empty release notes")
      expect { release.validate(@baseline, "HEAD") }.to raise_error("Missing nonempty changelog section: 1.1.0")
    end
  end
end
