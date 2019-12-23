require 'logger'
require 'json'
require 'rest-client'
require 'aws-sdk-ssm'
require 'aws-sdk-sqs'

def lambda_handler(event:, context:)
  sp = Sunpower.new(ENV["LOGLEVEL"].to_i)
  authorization = sp.authorize
  response = sp.get_data(authorization, "energy")
  readings = JSON.parse(response)
  sp.write_to_sqs(readings)
  return {
    :statusCode => 200,
    :body => {
      :message => "Success",
      :readings => readings["energyData"].size
  }.to_json
  }
end

class Sunpower
  API_BASE_URL = 'https://elhapi.edp.sunpower.com/v1/elh'.freeze
  POWER_API_BASE_URL = 'https://elhapi.edp.sunpower.com/v2/elh'.freeze

  def initialize(loglevel = Logger::INFO)
    puts "Sunpower init"
    @logger = Logger.new STDOUT
    @logger.level = loglevel
    RestClient.log = 'stdout' if @logger.level == Logger::DEBUG
  end
  
  def get_ssm_parameters(parameter_name, with_decryption = false)
    begin
      client = Aws::SSM::Client.new
      @logger.debug("client.get_parameter #{parameter_name}")
      value = client.get_parameter({:name => parameter_name, :with_decryption => with_decryption})
      return value

    rescue Aws::SSM::Errors::ServiceError => e
      @logger.error "SSM Service Error #{e.inspect}"
      exit(false)
    end
  end
  
  def authorize
    username = get_ssm_parameters("sunpower-username", true)
    password = get_ssm_parameters("sunpower-p", true)

    begin
      response = RestClient.post "#{API_BASE_URL}/authenticate",
                                  {
                                    username: username.parameter.value,
                                    password: password.parameter.value,
                                    isPersistent: true
                                  }.to_json,
                                   'Content-Type' => 'application/json'
      return JSON.parse response
    rescue Exception => e
      @logger.error "Exception #{e.inspect}"
    end
  end

  def get_data(authorization, category)
    yesterday_time = Time.now - (3600 * 24) 
    endtime   = yesterday_time.strftime("%Y-%m-%dT20:00:00")
    starttime = yesterday_time.strftime("%Y-%m-%dT06:00:00")
    url = category == "power" ? POWER_API_BASE_URL : API_BASE_URL 
    response = RestClient.get "#{url}/address/#{authorization['addressId']}/#{category}",
                              {:Authorization => "SP-CUSTOM #{authorization['tokenID']}",
                               :params => {:async => false,
                               :endtime => "#{endtime}",
                               :starttime => "#{starttime}",
                               :interval => "FIVE_MINUTE",
                               }}
    @logger.debug "#{category}"
    @logger.debug response
    response
  end
  
  def write_to_sqs(readings)
    sqs = Aws::SQS::Client.new
    queue_name = "sunpower-energy-queue"
    queue_url = "not initialized"
    
    begin
      queue_url = sqs.get_queue_url(queue_name: queue_name).queue_url
    rescue Aws::SQS::Errors::NonExistentQueue => e
      @logger.error "A queue named '#{queue_name}' does not exist. #{e.inspect}"
      exit(false)
    end

    readings["energyData"].each do |reading|
      sqs.send_message(queue_url: queue_url, message_body: reading)
    end
  end
end