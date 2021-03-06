#!/usr/bin/ruby1.9
#
# Capture events from Meraki CMX Location Push API, Version 1.0.
#
# DISCLAIMERS:
#
# 1. This code is for sample purposes only. Before running in production,
# you should probably add SSL/TLS support by running this server behind a
# TLS-capable reverse proxy like nginx.
#
# 2. You should also test that your server is capable of handling the rate
# of events that will be generated by your networks. A good rule of thumb is
# that your server should be able to process all your network's nodes once per
# minute. So if you have 100 nodes, your server should respond to each request
# within 600 ms. For more than 100 nodes, you will probably need a multithreaded
# web app.
#
# To use this webapp:
#
#   - Ensure you have ruby 1.9 installed
#   - Ensure that you have the sinatra gem installed; if you don't, do
#       gem install sinatra
#   - Ensure that you have the data_mapper gem installed; if you don't, do
#       gem install data_mapper
#
# Let's say you plan to run this server on a host called pushapi.example.com.
# Go to Meraki's Dashboard and configure the CMX Location Push API with the url
# "http://pushapi.example.com:4567/events", choose a secret, and make note of
# the validation code that Dashboard provides. Pass the secret and validation
# code to this server when you start it:
#
#   sample_location_server.rb <secret> <validator>
#
# You can change the bind interface (default 0.0.0.0) and port (default 4567)
# using Sinatra's -o and -p option flags:
#
#   sample_location_server.rb -o <interface> -p <port> <secret> <validator>
#
# Now click the "Validate server" link in CMX Location Push API configuration in
# Dashboard. Meraki's servers will perform a get to this server, and you will
# see a log message like this:
#
#   [26/Mar/2013 11:52:09] "GET /events HTTP/1.1" 200 6 0.0024
#
# If you do not see such a log message, check your firewall and make sure
# you're allowing connections to port 4567. You can confirm that the server
# is receiving connections on the port using
#
#   telnet pushapi.example.com 4567
#
# Once Dashboard has confirmed that the URL you provided returns the expected
# validation code, it will begin posting events to your URL. The events are
# encapsulated in a JSON post of the following form:
#
#   {"secret":<push secret>,"version":"2.0","type":"DevicesSeen","data":<data>}
#
# The "data" field is composed of the CMX data fields. For example:
#
#   {
#     "apFloors":"San Francisco>500 TF>5th"
#     "apMac":"11:22:33:44:55:66",
#     "observations":[
#       {
#         "clientMac":"aa:bb:cc:dd:ee:ff",
#         "seenTime":"1970-01-01T00:00:00Z",
#         "seenEpoch":0,
#         "ipv4":"/123.45.67.89",
#         "ipv6":"/ff11:2233:4455:6677:8899:0:aabb:ccdd",
#         "rssi":24,
#         "ssid":"Cisco WiFi",
#         "manufacturer":"Meraki",
#         "os":"Linux",
#         "location":{
#           "lat":37.77057805947924,
#           "lng":-122.38765965945927,
#           "unc":15.13174349529074
#         }
#       },...
#     ]
#   }
#
# This app will then begin logging the received JSON in a human-readable format.
# For example, when a client probes one of your access points, you'll see a log
# message like this:
#
#   [2013-03-26T11:51:57.920806 #25266]  INFO -- : AP 11:22:33:44:55:66 on ["5th Floor"]:
#   {"ipv4"=>"123.45.67.89", "location"=>{"lat"=>37.77050089978862, "lng"=>-122.38686903158863, 
#   "unc"=>11.39537928078731}, "seenTime"=>"2014-05-15T15:48:14Z", "ssid"=>"Cisco WiFi",
#   "os"=>"Linux", "clientMac"=>"aa:bb:cc:dd:ee:ff",
#   "seenEpoch"=>1400168894, "rssi"=>16, "ipv6"=>nil, "manufacturer"=>"Meraki"} 
#
# After your first client pushes start arriving (this may take a minute or two),
# you can get a JSON blob describing the last client probe using:
#
#   pushapi.example.com:4567/clients/{mac}
#
# where {mac} is the client mac address. For example,
#
#   http://pushapi.example.com:4567/clients/aa:bb:cc:dd:ee:ff
#
# may return
#
#   {"id":65,"mac":"aa:bb:cc:dd:ee:ff","seenAt":"2014-05-15T15.48.14Z",
#   "lat":37.77050089978862,"lng":-122.38686903158863,"unc":11.39537928078731,
#   "manufacturer":"Meraki","os":"Linux","floors":["5th Floor"]}
#
# You can also view the sample frontend at
#
#   http://pushapi.example.com:4567/
#
# Try connecting your mobile to your network, and entering your mobile's WiFi MAC in
# the frontend.

require 'rubygems'
require 'sinatra'
require 'data_mapper'
require 'json'
require 'digest/sha1'

# ---- Set up Sinatra -----

# zip content when possible
use Rack::Deflater

# ---- Parse command-line arguments ----

if ARGV.size < 2
  # The sinatra gem parses the -o and -p options for us.
  puts "usage: sample_push_api_server.rb [-o <addr>] [-p <port>] <secret> <validator>"
  exit 1
end

argOff = 0

if ARGV[0] == '-o' or ARGV[0] == '-p'
  argOff += 2
end
if ARGV[2] == '-o' or ARGV[2] == '-p'
  argOff += 2
end

SECRET = ARGV[argOff]
puts "SECRET is #{SECRET}"
VALIDATOR = ARGV[argOff + 1]
puts "VALIDATOR is #{VALIDATOR}"

db = ENV['DATABASE_URL']
puts "Writing database to #{db}"

# ---- Load anonimization data --------

# NAMES = CSV.read("initials.csv")
# puts "Loaded #{NAMES.length} names"

# ---- Set up the database -------------

DataMapper.setup(:default, db)

class Client
  include DataMapper::Resource

  property :id,         Serial                    # row key
  property :mac,        String,  :key => true
  property :seenString, String
  property :seenEpoch,  Integer, :default => 0, :index => true
  property :lat,        Float
  property :lng,        Float
  property :unc,        Float
  property :manufacturer, String
  property :os,         String
  property :ssid,       String
  property :floors,     String
end

DataMapper.finalize

DataMapper.auto_migrate!    # Creates your schema in the database

# ---- Set up routes -------------------

# Serve the frontend.
get '/' do
  send_file File.join(settings.public_folder, 'index.html')
end

# This is used by the Meraki API to validate this web app.
# In general it is a Bad Thing to change this.
get '/events' do
  VALIDATOR
end

# Respond to Meraki's push events. Here we're just going
# to write the most recent events to our database.
post '/events' do
  if request.media_type != "application/json"
    logger.warn "got post with unexpected content type: #{request.media_type}"
    return
  end
  request.body.rewind
  map = JSON.parse(request.body.read)
  if map['secret'] != SECRET
    logger.warn "got post with bad secret: #{map['secret']}"
    return
  end
  logger.info "version is #{map['version']}"
  if map['version'] != '2.0'
    logger.warn "got post with unexpected version: #{map['version']}"
    return
  end
  if map['type'] != 'DevicesSeen'
    logger.warn "got post for event that we're not interested in: #{map['type']}"
    return
  end
  map['data']['observations'].each do |c|
    loc = c['location']
    next if loc == nil
    name = c['clientMac']
    lat = loc['lat']
    lng = loc['lng']
    seenString = c['seenTime']
    seenEpoch = c['seenEpoch']
    floors = map['data']['apFloors'] == nil ? "" : map['data']['apFloors'].join
    logger.info "AP #{map['data']['apMac']} on #{map['data']['apFloors']}: #{c}"
    next if (seenEpoch == nil || seenEpoch == 0)  # This probe is useless, so ignore it
    client = Client.first_or_create(:mac => name)
    if (seenEpoch > client.seenEpoch)             # If client was created, this will always be true
      client.attributes = { :lat => lat, :lng => lng,
                            :seenString => seenString, :seenEpoch => seenEpoch,
                            :unc => loc['unc'],
                            :manufacturer => c['manufacturer'], :os => c['os'],
                            :ssid => c['ssid'],
                            :floors => floors
                          }
      client.save
    end
  end
  ""
end

# Serve client data from the database.

# This matches
#    /clients/<mac>
# and returns a client with a given mac address, or empty JSON
# if the mac is not in the database.
get '/clients/:mac' do |m|
  name = m.sub "%20", " "
  puts "Request name is #{name}"
  content_type :json
  client = Client.first(:mac => name)
  logger.info("Retrieved client #{client}")
  client != nil ? JSON.generate(client) : "{}"
end

# This matches
#   /clients OR /clients/
# and returns a JSON blob of all clients.
get %r{/clients/?} do
  content_type :json
  clients = Client.all(:seenEpoch.gt => (Time.new - 300).to_i)
  JSON.generate(clients)
end
