require 'capybara/rails'
require 'capybara/rspec'
require 'selenium-webdriver'
require 'fileutils'

driver = ENV.fetch("CAPYBARA_DRIVER", "selenium_chrome_headless").to_sym

case driver
  when :webkit
    Capybara.register_driver :webkit do |app|
      browser = Capybara::Webkit::Browser.new(Capybara::Webkit::Connection.new).tap do |browser|
        browser.ignore_ssl_errors
      end
      Capybara::Webkit::Driver.new(app, browser: browser)
    end
  when :poltergeist
    require 'capybara/poltergeist'

    url_whitelist = ENV.fetch("CAPYBARA_URL_WHITELIST", ['http://127.0.0.1'])
    url_blacklist = ENV.fetch("CAPYBARA_URL_BLACKLIST", ['*.ttf', '*.woff'])

    Capybara.register_driver :poltergeist do |app|
      Capybara::Poltergeist::Driver.new(
        app,
        js_errors: ENV['POLTERGEIST_JS_ERRORS_RAISE'] == '1',
        logger: File.open(Rails.root.join('log/capybara.log'), 'w'),
        phantomjs_logger: File.open(Rails.root.join('log/test-javascript.log'), 'w'),
        url_whitelist: url_whitelist,
        url_blacklist: url_blacklist,
        timeout: 60
      )
    end
  when :selenium_chrome_headless
    Capybara.register_driver :selenium_chrome_headless do |app|
      args = %w(headless disable-gpu disable-dev-shm-usage no-sandbox window-size=1280,1024)

      Capybara::Selenium::Driver.new app,
        browser: :chrome,
        options: Selenium::WebDriver::Chrome::Options.new(args: args),
        http_client: Selenium::WebDriver::Remote::Http::Default.new(
          read_timeout: ENV.fetch('SELENIUM_READ_TIMEOUT', '60').to_i,
        )
    end
  when :selenium_remote_chrome
    url = ENV.fetch("SELENIUM_REMOTE_URL", "http://localhost:4444/wd/hub")

    Capybara.register_driver driver do |app|
      Capybara::Selenium::Driver.new(
        app,
        browser: :remote,
        capabilities: %i(chrome),
        url: url,
        http_client: Selenium::WebDriver::Remote::Http::Default.new(
          read_timeout: ENV.fetch('SELENIUM_READ_TIMEOUT', '60').to_i,
        ),
      ).tap do |driver|
        driver.browser.manage.window.size = Selenium::WebDriver::Dimension.new(1280, 1024)
        driver.browser.file_detector = ->(args) {
          str = args.first.to_s
          str if File.exist?(str)
        }
      end
    end
  else
    Capybara.register_driver driver do |app|
      Capybara::Selenium::Driver.new(app, browser: driver)
    end
end

Capybara.configure do |config|
  config.match = :one
  config.ignore_hidden_elements = true
  config.visible_text_only = true
  config.default_driver = driver
  config.javascript_driver = driver

  config.default_max_wait_time = ENV.fetch('CAPYBARA_WAIT_TIME', 10).to_i
  config.default_normalize_ws = true if config.respond_to?(:default_normalize_ws=)
end

module CapybaraScreenshotHelpers
  def self.screenshot_directory
    @screenshot_directory ||= Rails.root.join("spec", "error_screenshots", ENV.fetch("SCREENSHOT_DIR", Time.now.to_i.to_s))
  end

  def screenshot(filename)
    options = {}
    case Capybara.current_driver
      when :webkit
        options[:width] = page.driver.evaluate_script("document.documentElement.clientWidth")
        options[:height] = page.driver.evaluate_script("document.documentElement.clientHeight")
      when :poltergeist
        options[:full] = true
    end
    page.save_screenshot "#{filename}", options
  end

  private

  def screenshot_on_error(example)
    if example.exception.present?
      filename = "#{example.metadata[:full_description]}.png".gsub(/\ /, "_")
      screenshot "#{CapybaraScreenshotHelpers.screenshot_directory}/#{filename}"
    end
  end
end

RSpec.configure do |config|
  config.include CapybaraScreenshotHelpers, type: :feature

  config.after(:each, type: :feature) do |example|
    # Specs that never exercise the page will not be properly reset: https://github.com/teamcapybara/capybara/blob/866c975076f92b5d064ee8998be638dd213f0724/lib/capybara/session.rb#L111
    raise "#{example.metadata[:description]} did not exercise the page" unless page.instance_variable_get(:@touched)

    screenshot_on_error example
    Capybara.reset_sessions!
  end

  config.after(:suite) do
    error_screenshot_directory = CapybaraScreenshotHelpers.screenshot_directory
    puts "\nError screenshots saved to: #{error_screenshot_directory}" if File.directory?("#{error_screenshot_directory}")

    # remove any paperclip attachments
    FileUtils.rm_rf(Dir["#{Rails.root}/spec/test_files/"])
  end

  config.before(:each, type: :system) do
    driven_by driver
  end
end
