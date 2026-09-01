source "https://rubygems.org"
git_source(:github) { |repo_name| "https://github.com/#{repo_name}" }
ruby ">= 3.4"
gemspec

group :test do
  gem "rspec", require: false
end

group :lint do
  # use `bundle exec rubocop` to lint.
  gem "standard", require: false
  gem "rubocop-rspec", require: false
end

group :documentation do
  gem "rake", require: false
  gem "rdoc", require: false
end

group :benchmark do
  gem "benchmark-ips", require: false
  gem "json-schema", path: "references/json-schema", require: false
  gem "json_schemer", path: "references/json_schemer", require: false
  gem "ruby-prof", require: false
end
