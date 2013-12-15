#!/usr/bin/env ruby

require 'sinatra'
require 'file-tail'
require 'action_view'

set :port, 8000
set :bind, "0.0.0.0"

class StarboundPanel
  attr_accessor :log_path, :state_path

  def self.load(log_path)
    state_path = File.join(File.dirname(log_path), ".sbpanel")

    state = nil
    if File.exists?(state_path)
      begin
        state = Marshal.load(File.read(state_path))
        puts "Loaded sbpanel state from #{state_path}"
      rescue Exception
        puts "Error loading sbpanel state, making new panel"
      end
    end

    panel = StarboundPanel.new(state)

    panel.log_path = log_path
    panel.state_path = state_path
    panel.update_status
    panel
  end

  def initialize(state)
    @address = "starbound.mispy.me"
    @port = 21025
    
    @players = state[:players] || {} # Persist info for players we've seen
    @worlds = state[:worlds] || {} # Persist info for worlds we've seen
    @last_status_change = state[:last_status_change] || Time.now # Persist last observed status change

    @status = :unknown # Whether we're offline/online
    @version = 'unknown' # Server version
    @online_players = [] # Players we've seen connect
    @active_worlds = [] # Worlds we've seen activated
    @offline_players = @players.values.select { |pl| !@online_players.include?(pl) }

    @timing = false # We read the log initially without timing
  end

  def save
    File.open(@state_path, 'w') do |f|
      f.write(Marshal.dump({
        players: @players,
        worlds: @worlds,
        last_status_change: @last_status_change 
      }))
    end
  end

  # Detect server status
  # Looks for processes which have log file open for writing
  def update_status
    status = :offline
    fuser = `fuser -v #{@log_path} 2>&1`.split("\n")[2..-1]
    
    if fuser
      fuser.each do |line|
        if line.strip.split[2].include?('F')
          status = :online
        end
      end
    end

    if status != @status
      time = Time.now
      if status == :offline
        puts "Server is currently offline"
      else
        puts "Server is currently online"
      end

      @status = status
      @last_status_change = time if @timing
    end
  end

  def parse_line(line, time)
    events = {
      version: /^Info: Server version '(.+?)'/,
      login: /^Info: Client '(.+?)' <.> \(.+?\) connected$/,
      logout: /^Info: Client '(.+?)' <.> \(.+?\) disconnected$/,
      world: /^Info: Loading world db for world (.+?)$/,
      unworld: /^Info: Shutting down world (.+?)$/
    }

    events.each do |name, regex|
      event = regex.match(line)
      next unless event

      case name
      when :version
        puts "Server version: #{event[1]}"
        @version = event[1]
      when :login
        name = event[1]

        player = @players[name] || {}
        player[:name] = name
        player[:last_connect] = time if @timing
        @players[name] = player

        @online_players.push(player)
        @offline_players.delete_if { |pl| pl[:name] == name }
        puts "#{name} connected at #{player[:last_connect]}"
      when :logout
        name = event[1]

        player = @players[name] || {}
        player[:name] = name
        player[:last_disconnect] = time if @timing
        @players[name] = player

        @online_players.delete_if { |pl| pl[:name] == name }
        @offline_players.push(player)
        puts "#{name} disconnected at #{player[:last_disconnect]}"
      when :world
        coords = event[1]

        world = @worlds[coords] || {}
        world[:coords] = coords
        world[:last_load] = time if @timing
        @worlds[coords] ||= world

        @active_worlds.push(world)
        puts "Loaded world #{coords}"
      when :unworld
        coords = event[1]

        world = @worlds[coords] || {}
        world[:coords] = coords
        world[:last_unload] = time if @timing
        @worlds[coords] ||= world

        @active_worlds.delete_if { |w| w[:coords] == coords }
        puts "Unloaded world #{coords}"
      end

      if @timing
        # For post-initial-load events, check server
        # status and save state updates
        update_status; save
      end
    end
  end

  def read_logs
    # Initial read without timing
    File.read(@log_path).each_line do |line|
      parse_line(line, nil)
    end

    @timing = true
    log = File.open(@log_path)
    log.extend(File::Tail)
    log.backward(0)
    log.tail do |line|
      parse_line(line, Time.now)
    end

    log.close
  end
end

panel = StarboundPanel.load(ARGV[0])

Thread.new do
  begin
    panel.read_logs
  rescue Exception => e
    puts e.message
    puts e.backtrace.join("\n")
  end
end

helpers ActionView::Helpers::DateHelper

get '/' do
  panel.update_status
  panel.instance_variables.each do |var|
    instance_variable_set var, panel.instance_variable_get(var)
  end
  erb :index
end