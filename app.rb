require 'sinatra'
require 'sinatra/reloader' if development?

require 'aws-sdk-ec2'
require 'aws-sdk-health'
require 'action_view'
require 'digest/sha1'

helpers do
  include ActionView::Helpers::TextHelper

  def h(text)
    Rack::Utils.escape_html(text)
  end

  def auto_link(text)
    text.gsub(%r|\bhttps?://[^\s<]+\b|) do |m|
      %!<a href="#{m}" target="_blank">#{m}</a>!
    end
  end

  def aws_service_link(region, name)
    prefix = region == 'global' ? '' : "#{region}."
    %!<a href="https://#{prefix}console.aws.amazon.com/#{name.downcase}" target="_blank">#{name}</a>!
  end

  def instance_link(region, instance_id)
    prefix = region == 'global' ? '' : "#{region}."
    %!<a href="https://#{prefix}console.aws.amazon.com/ec2#Instances:instanceId=#{instance_id}" target="_blank">#{instance_id}</a>!
  end
end

set :cache, nil
set :loader, nil
set :ttl, 3600
set :mutex, Mutex.new

def fetch_health
  client = Aws::Health::Client.new(region: 'us-east-1')

  events = client.describe_events(filter: {event_status_codes: %w(open upcoming)}).each_page.flat_map(&:events)

  event_details = events.map(&:arn).each_slice(10).flat_map {|arns|
    client.describe_event_details(event_arns: arns).each_page.flat_map(&:successful_set)
  }

  event_detail_by_arn = event_details.reduce({}) {|r, e|
    r[e.event.arn] = e
    r
  }

  entities = event_detail_by_arn.keys.each_slice(10).flat_map {|arns|
    client.describe_affected_entities(filter: {event_arns: arns}).each_page.flat_map(&:entities)
  }

  entities_by_event_arn = entities.reduce({}) {|r, e|
    r[e.event_arn] ||=[]
    r[e.event_arn] << e
    r
  }

  ec2_by_region = events.map(&:region).uniq.reduce({}) {|r, region|
    r[region] = Aws::EC2::Resource.new(region: region)
    r
  }

  {
    start_time: erb(:index, locals: {event_detail_by_arn: event_detail_by_arn, entities_by_event_arn: entities_by_event_arn, ec2_by_region: ec2_by_region, sort: :start_time}),
    last_updated_time: erb(:index, locals: {event_detail_by_arn: event_detail_by_arn, entities_by_event_arn: entities_by_event_arn, ec2_by_region: ec2_by_region, sort: :last_updated_time}),
  }
end

get '/' do
  sort = (params[:sort] || 'start_time').to_sym

  if settings.production?
    settings.mutex.synchronize do
      if settings.cache.nil?
        loading_view = erb :loading

        settings.cache = {
          start_time: loading_view,
          last_updated_time: loading_view,
        }

        settings.loader = Thread.new do
          loop do
            settings.cache = fetch_health
            sleep settings.production? ? settings.ttl : 3
          end
        end
      end
    end

    settings.cache.fetch(sort)
  else
    fetch_health.fetch(sort)
  end
end

get '/update' do
  settings.mutex.synchronize do
    loading_view = erb :loading

    settings.cache = {
      start_time: loading_view,
      last_updated_time: loading_view,
    }

    settings.loader.run
  end

  redirect '/'
end

get '/ping' do
  'OK'
end
