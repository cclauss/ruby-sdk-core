# frozen_string_literal: true

require_relative("./../test_helper.rb")
require("webmock/minitest")

WebMock.disable_net_connect!(allow_localhost: true)

# Unit tests for the ICP4D Token Manager
class ICP4DTokenManagerTest < Minitest::Test
  def test_request_token
    response = {
      "access_token" => "oAeisG8yqPY7sFR_x66Z15",
      "token_type" => "Bearer",
      "expires_in" => 3600,
      "expiration" => 1_524_167_011,
      "refresh_token" => "jy4gl91BQ"
    }

    token_manager = IBMCloudSdkCore::ICP4DTokenManager.new(
      url: "https://the.sixth.one",
      username: "you",
      password: "me"
    )
    stub_request(:get, "https://the.sixth.one/v1/preauth/validateAuth")
      .with(
        headers: {
          "Authorization" => "Basic eW91Om1l",
          "Host" => "the.sixth.one"
        }
      ).to_return(status: 200, body: response.to_json, headers: {})
    token_response = token_manager.send(:request_token)
    assert_equal(response, token_response)
    token_manager.access_token("token")
    assert_equal(token_manager.instance_variable_get(:@user_access_token), "token")
  end

  def test_request_token_fails
    token_manager = IBMCloudSdkCore::ICP4DTokenManager.new(
      url: "https://the.sixth.one",
      username: "you",
      password: "me"
    )
    response = {
      "code" => "500",
      "error" => "Oh no"
    }
    stub_request(:get, "https://the.sixth.one/v1/preauth/validateAuth")
      .with(
        headers: {
          "Authorization" => "Basic eW91Om1l",
          "Host" => "the.sixth.one"
        }
      ).to_return(status: 500, body: response.to_json, headers: {})
    begin
      token_manager.send(:request_token)
    rescue IBMCloudSdkCore::ApiException => e
      assert(e.to_s.instance_of?(String))
    end
  end
end
