#!/usr/bin/env ruby
# Generate from the verified archive, never from a second version authority.
require "digest"
require "fileutils"

version = File.read(File.expand_path("../VERSION", __dir__)).strip
abort "Invalid VERSION" unless /\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\z/.match?(version)
archive, tap = ARGV
abort "Usage: update-tap.rb ARCHIVE TAP_DIRECTORY" unless archive && tap && ARGV.length == 2
expected = "McDiff-#{version}-macos-universal.zip"
abort "Expected #{expected}" unless File.basename(archive) == expected
abort "Tap checkout not found" unless File.directory?(File.join(tap, ".git"))
checksum = Digest::SHA256.file(archive).hexdigest
FileUtils.mkdir_p(File.join(tap, "Casks"))
File.write(File.join(tap, "Casks/mcdiff.rb"), <<~CASK)
  cask "mcdiff" do
    version "#{version}"
    sha256 "#{checksum}"

    url "https://github.com/Nek-12/mcdiff/releases/download/v\#{version}/McDiff-\#{version}-macos-universal.zip"
    name "McDiff"
    desc "Native code review for agent-generated changes"
    homepage "https://github.com/Nek-12/mcdiff"

    depends_on macos: :tahoe

    app "McDiff.app"
  end
CASK
