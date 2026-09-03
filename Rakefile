# frozen_string_literal: true

require "rake/clean"

CLEAN.include("ext/schemurai_native/*.o", "ext/schemurai_native/*.so", "ext/schemurai_native/Makefile")

desc "Build the native VM backend"
task :compile do
  Dir.chdir("ext/schemurai_native") do
    ruby "extconf.rb" unless File.exist?("Makefile")
    sh "make"
  end
end

begin
  require "rdoc/task"

  RDoc::Task.new do |rdoc|
    rdoc.main = "README.md"
    rdoc.options << "--visibility=public"
    rdoc.rdoc_dir = "rdoc"
    rdoc.title = "Schemurai API Documentation"
    rdoc.rdoc_files.include("README.md", "LICENSE", "lib/schemurai.rb", "lib/schemurai/version.rb")
  end
rescue LoadError
  # Native compilation does not require the optional documentation bundle.
end
