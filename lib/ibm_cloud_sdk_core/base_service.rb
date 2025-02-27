# frozen_string_literal: true

require("http")
require("rbconfig")
require("stringio")
require("json")
require_relative("./detailed_response.rb")
require_relative("./api_exception.rb")
require_relative("./iam_token_manager.rb")
require_relative("./icp4d_token_manager.rb")
require_relative("./version.rb")

DEFAULT_CREDENTIALS_FILE_NAME = "ibm-credentials.env"
NORMALIZER = lambda do |uri| # Custom URI normalizer when using HTTP Client
  HTTP::URI.parse uri
end

module IBMCloudSdkCore
  # Class for interacting with the API
  class BaseService
    attr_accessor :password, :url, :username, :display_name
    attr_reader :conn, :token_manager
    def initialize(vars)
      defaults = {
        vcap_services_name: nil,
        use_vcap_services: true,
        authentication_type: nil,
        username: nil,
        password: nil,
        icp4d_access_token: nil,
        icp4d_url: nil,
        iam_apikey: nil,
        iam_access_token: nil,
        iam_url: nil,
        iam_client_id: nil,
        iam_client_secret: nil,
        display_name: nil
      }
      vars = defaults.merge(vars)
      @url = vars[:url]
      @username = vars[:username]
      @password = vars[:password]
      @icp_prefix = vars[:password]&.start_with?("icp-") || vars[:iam_apikey]&.start_with?("icp-") ? true : false
      @icp4d_access_token = vars[:icp4d_access_token]
      @icp4d_url = vars[:icp4d_url]
      @iam_url = vars[:iam_url]
      @iam_apikey = vars[:iam_apikey]
      @iam_access_token = vars[:iam_access_token]
      @token_manager = nil
      @authentication_type = vars[:authentication_type].downcase unless vars[:authentication_type].nil?
      @temp_headers = nil
      @disable_ssl_verification = false
      @display_name = vars[:display_name]

      if vars[:use_vcap_services] && !@username && !@iam_apikey
        @vcap_service_credentials = load_from_vcap_services(service_name: vars[:vcap_services_name])
        if !@vcap_service_credentials.nil? && @vcap_service_credentials.instance_of?(Hash)
          @url = @vcap_service_credentials["url"]
          @username = @vcap_service_credentials["username"] if @vcap_service_credentials.key?("username")
          @password = @vcap_service_credentials["password"] if @vcap_service_credentials.key?("password")
          @iam_apikey = @vcap_service_credentials["iam_apikey"] if @vcap_service_credentials.key?("iam_apikey")
          @iam_access_token = @vcap_service_credentials["iam_access_token"] if @vcap_service_credentials.key?("iam_access_token")
          @icp4d_access_token = @vcap_service_credentials["icp4d_access_token"] if @vcap_service_credentials.key?("icp4d_access_token")
          @icp4d_url = @vcap_service_credentials["icp4d_url"] if @vcap_service_credentials.key?("icp4d_url")
          @iam_url = @vcap_service_credentials["iam_url"] if @vcap_service_credentials.key?("iam_url")
          @icp_prefix = @password&.start_with?("icp-") || @iam_apikey&.start_with?("icp-") ? true : false
        end
      end

      if @display_name && !@username && !@iam_apikey
        service_name = @display_name.sub(" ", "_").downcase
        load_from_credential_file(service_name)
        @icp_prefix = @password&.start_with?("icp-") || @iam_apikey&.start_with?("icp-") ? true : false
      end

      if @authentication_type == "iam" || ((!@iam_access_token.nil? || !@iam_apikey.nil?) && !@icp_prefix)
        iam_token_manager(iam_apikey: @iam_apikey, iam_access_token: @iam_access_token,
                          iam_url: @iam_url, iam_client_id: @iam_client_id,
                          iam_client_secret: @iam_client_secret)
      elsif !@iam_apikey.nil? && @icp_prefix
        @username = "apikey"
        @password = vars[:iam_apikey]
      elsif @authentication_type == "icp4d" || !@icp4d_access_token.nil?
        icp4d_token_manager(icp4d_access_token: @icp4d_access_token, icp4d_url: @icp4d_url,
                            username: @username, password: @password)
      elsif !@username.nil? && !@password.nil?
        if @username == "apikey" && !@icp_prefix
          iam_apikey(iam_apikey: @password)
        else
          @username = @username
          @password = @password
        end
      end

      raise ArgumentError.new('The username shouldn\'t start or end with curly brackets or quotes. Be sure to remove any {} and \" characters surrounding your username') if check_bad_first_or_last_char(@username)
      raise ArgumentError.new('The password shouldn\'t start or end with curly brackets or quotes. Be sure to remove any {} and \" characters surrounding your password') if check_bad_first_or_last_char(@password)
      raise ArgumentError.new('The url shouldn\'t start or end with curly brackets or quotes. Be sure to remove any {} and \" characters surrounding your url') if check_bad_first_or_last_char(@url)
      raise ArgumentError.new('The apikey shouldn\'t start or end with curly brackets or quotes. Be sure to remove any {} and \" characters surrounding your apikey') if check_bad_first_or_last_char(@iam_apikey)
      raise ArgumentError.new('The iam access token  shouldn\'t start or end with curly brackets or quotes. Be sure to remove any {} and \" characters surrounding your iam access token') if check_bad_first_or_last_char(@iam_access_token)
      raise ArgumentError.new('The icp4d access token  shouldn\'t start or end with curly brackets or quotes. Be sure to remove any {} and \" characters surrounding your icp4d access token') if check_bad_first_or_last_char(@icp4d_access_token)
      raise ArgumentError.new('The icp4d url shouldn\'t start or end with curly brackets or quotes. Be sure to remove any {} and \" characters surrounding your icp4d url') if check_bad_first_or_last_char(@icp4d_url)

      @conn = HTTP::Client.new(
        headers: {}
      ).use normalize_uri: { normalizer: NORMALIZER }
    end

    # Initiates the credentials based on the credential file
    def load_from_credential_file(service_name, separator = "=")
      credential_file_path = ENV["IBM_CREDENTIALS_FILE"]

      # Home directory
      if credential_file_path.nil?
        file_path = ENV["HOME"] + "/" + DEFAULT_CREDENTIALS_FILE_NAME
        credential_file_path = file_path if File.exist?(file_path)
      end

      # Top-level directory of the project
      if credential_file_path.nil?
        file_path = File.join(File.dirname(__FILE__), "/../../" + DEFAULT_CREDENTIALS_FILE_NAME)
        credential_file_path = file_path if File.exist?(file_path)
      end

      return if credential_file_path.nil?

      file_contents = File.open(credential_file_path, "r")
      file_contents.each_line do |line|
        key_val = line.strip.split(separator)
        set_credential_based_on_type(service_name, key_val[0].downcase, key_val[1]) if key_val.length == 2
      end
    end

    def load_from_vcap_services(service_name:)
      vcap_services = ENV["VCAP_SERVICES"]
      unless vcap_services.nil?
        services = JSON.parse(vcap_services)
        return services[service_name][0]["credentials"] if services.key?(service_name)
      end
      nil
    end

    def add_default_headers(headers: {})
      raise TypeError unless headers.instance_of?(Hash)

      headers.each_pair { |k, v| @conn.default_options.headers.add(k, v) }
    end

    def iam_access_token(iam_access_token:)
      @token_manager = IAMTokenManager.new(iam_access_token: iam_access_token) if @token_manager.nil?
      @iam_access_token = iam_access_token
    end

    def iam_apikey(iam_apikey:)
      @token_manager = IAMTokenManager.new(iam_apikey: iam_apikey) if @token_manager.nil?
      @iam_apikey = iam_apikey
    end

    # @return [DetailedResponse]
    def request(args)
      defaults = { method: nil, url: nil, accept_json: false, headers: nil, params: nil, json: {}, data: nil }
      args = defaults.merge(args)
      args[:data].delete_if { |_k, v| v.nil? } if args[:data].instance_of?(Hash)
      args[:json] = args[:data].merge(args[:json]) if args[:data].respond_to?(:merge)
      args[:json] = args[:data] if args[:json].empty? || (args[:data].instance_of?(String) && !args[:data].empty?)
      args[:json].delete_if { |_k, v| v.nil? } if args[:json].instance_of?(Hash)
      args[:headers]["Accept"] = "application/json" if args[:accept_json] && args[:headers]["Accept"].nil?
      args[:headers]["Content-Type"] = "application/json" unless args[:headers].key?("Content-Type")
      args[:json] = args[:json].to_json if args[:json].instance_of?(Hash)
      args[:headers].delete_if { |_k, v| v.nil? } if args[:headers].instance_of?(Hash)
      args[:params].delete_if { |_k, v| v.nil? } if args[:params].instance_of?(Hash)
      args[:form].delete_if { |_k, v| v.nil? } if args.key?(:form)
      args.delete_if { |_, v| v.nil? }
      args[:headers].delete("Content-Type") if args.key?(:form) || args[:json].nil?

      if @username == "apikey" && !@icp_prefix
        iam_apikey(iam_apikey: @password)
        @username = nil
      end

      conn = @conn
      if !@iam_apikey.nil? && @icp_prefix
        conn = @conn.basic_auth(user: "apikey", pass: @iam_apikey)
      elsif !@token_manager.nil?
        access_token = @token_manager.token
        args[:headers]["Authorization"] = "Bearer #{access_token}"
      elsif !@username.nil? && !@password.nil?
        conn = @conn.basic_auth(user: @username, pass: @password)
      end

      args[:headers] = args[:headers].merge(@temp_headers) unless @temp_headers.nil?
      @temp_headers = nil unless @temp_headers.nil?

      if args.key?(:form)
        response = conn.follow.request(
          args[:method],
          HTTP::URI.parse(@url + args[:url]),
          headers: conn.default_options.headers.merge(HTTP::Headers.coerce(args[:headers])),
          params: args[:params],
          form: args[:form]
        )
      else
        response = conn.follow.request(
          args[:method],
          HTTP::URI.parse(@url + args[:url]),
          headers: conn.default_options.headers.merge(HTTP::Headers.coerce(args[:headers])),
          body: args[:json],
          params: args[:params]
        )
      end
      return DetailedResponse.new(response: response) if (200..299).cover?(response.code)

      raise ApiException.new(response: response)
    end

    # @note Chainable
    # @param headers [Hash] Custom headers to be sent with the request
    # @return [self]
    def headers(headers)
      raise TypeError("Expected Hash type, received #{headers.class}") unless headers.instance_of?(Hash)

      @temp_headers = headers
      self
    end

    # @!method configure_http_client(proxy: {}, timeout: {}, disable_ssl_verification: false)
    # Sets the http client config, currently works with timeout and proxies
    # @param proxy [Hash] The hash of proxy configurations
    # @option proxy address [String] The address of the proxy
    # @option proxy port [Integer] The port of the proxy
    # @option proxy username [String] The username of the proxy, if authentication is needed
    # @option proxy password [String] The password of the proxy, if authentication is needed
    # @option proxy headers [Hash] The headers to be used with the proxy
    # @param timeout [Hash] The hash for configuring timeouts. `per_operation` has priority over `global`
    # @option timeout per_operation [Hash] Timeouts per operation. Requires `read`, `write`, `connect`
    # @option timeout global [Integer] Upper bound on total request time
    # @param disable_ssl_verification [Boolean] Disable the SSL verification (Note that this has serious security implications - only do this if you really mean to!)
    def configure_http_client(proxy: {}, timeout: {}, disable_ssl_verification: false)
      raise TypeError("proxy parameter must be a Hash") unless proxy.empty? || proxy.instance_of?(Hash)

      raise TypeError("timeout parameter must be a Hash") unless timeout.empty? || timeout.instance_of?(Hash)

      @disable_ssl_verification = disable_ssl_verification
      if disable_ssl_verification
        ssl_context = OpenSSL::SSL::SSLContext.new
        ssl_context.verify_mode = OpenSSL::SSL::VERIFY_NONE
        @conn.default_options = { ssl_context: ssl_context }

        @token_manager&.ssl_verification(true)
      end
      add_proxy(proxy) unless proxy.empty? || !proxy.dig(:address).is_a?(String) || !proxy.dig(:port).is_a?(Integer)
      add_timeout(timeout) unless timeout.empty? || (!timeout.key?(:per_operation) && !timeout.key?(:global))
    end

    private

    def set_credential_based_on_type(service_name, key, value)
      return unless key.include?(service_name)

      @iam_apikey = value if key.include?("iam_apikey")
      @iam_url = value if key.include?("iam_url")
      @url = value if key.include?("url")
      @username = value if key.include?("username")
      @password = value if key.include?("password")
    end

    def check_bad_first_or_last_char(str)
      return str.start_with?("{", "\"") || str.end_with?("}", "\"") unless str.nil?
    end

    def iam_token_manager(iam_apikey: nil, iam_access_token: nil, iam_url: nil,
                          iam_client_id: nil, iam_client_secret: nil)
      @iam_apikey = iam_apikey
      @iam_access_token = iam_access_token
      @iam_url = iam_url
      @iam_client_id = iam_client_id
      @iam_client_secret = iam_client_secret
      @token_manager =
        IAMTokenManager.new(iam_apikey: iam_apikey, iam_access_token: iam_access_token,
                            iam_url: iam_url, iam_client_id: iam_client_id, iam_client_secret: iam_client_secret)
    end

    def icp4d_token_manager(icp4d_access_token: nil, icp4d_url: nil, username: nil, password: nil)
      if !@token_manager.nil?
        @token_manager.access_token(icp4d_access_token)
      else
        raise ArgumentError.new("The icp4d_url is mandatory for ICP4D.") if icp4d_url.nil? && icp4d_access_token.nil?

        @token_manager = ICP4DTokenManager.new(url: icp4d_url, access_token: icp4d_access_token, username: username, password: password)
      end
    end

    def add_timeout(timeout)
      if timeout.key?(:per_operation)
        raise TypeError("per_operation in timeout must be a Hash") unless timeout[:per_operation].instance_of?(Hash)

        defaults = {
          write: 0,
          connect: 0,
          read: 0
        }
        time = defaults.merge(timeout[:per_operation])
        @conn = @conn.timeout(write: time[:write], connect: time[:connect], read: time[:read])
      else
        raise TypeError("global in timeout must be an Integer") unless timeout[:global].is_a?(Integer)

        @conn = @conn.timeout(timeout[:global])
      end
    end

    def add_proxy(proxy)
      if (proxy[:username].nil? || proxy[:password].nil?) && proxy[:headers].nil?
        @conn = @conn.via(proxy[:address], proxy[:port])
      elsif !proxy[:username].nil? && !proxy[:password].nil? && proxy[:headers].nil?
        @conn = @conn.via(proxy[:address], proxy[:port], proxy[:username], proxy[:password])
      elsif !proxy[:headers].nil? && (proxy[:username].nil? || proxy[:password].nil?)
        @conn = @conn.via(proxy[:address], proxy[:port], proxy[:headers])
      else
        @conn = @conn.via(proxy[:address], proxy[:port], proxy[:username], proxy[:password], proxy[:headers])
      end
    end
  end
end
