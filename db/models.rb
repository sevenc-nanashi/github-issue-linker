require "active_record"
require "octokit"

path = "#{__dir__}/config.yml"
raw_config = File.read(path)
configuration = YAML.safe_load(raw_config)[ENV["PRODUCTION"] ? "production" : "development"]
ActiveRecord::Base.establish_connection(configuration)

class Pat < ActiveRecord::Base
  def client
    Octokit::Client.new(access_token: pat)
  end
end
