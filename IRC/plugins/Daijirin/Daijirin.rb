# encoding: utf-8
# This file is part of the K5 bot project.
# See files README.md and COPYING for copyright and licensing information.

# Daijirin plugin

require_relative '../../IRCPlugin'
require_relative 'DaijirinEntry'

class Daijirin < IRCPlugin
  Description = "An Daijirin plugin."
  Commands = {
    :dj => "looks up a Japanese word in Daijirin",
    :de => "looks up an English word in Daijirin",
    :dn => "returns the next list of entries from Daijirin"
  }
  Dependencies = [ :Language ]

  def afterLoad
    @menusize = 12 # size of menu
    @expire = 1920 # time in seconds until entry expires
    begin
      Object.send :remove_const, :DaijirinEntry
      load "#{plugin_root}/DaijirinEntry.rb"
    rescue ScriptError, StandardError => e
      puts "Cannot load DaijirinEntry: #{e}"
    end
    @l = @bot.pluginManager.plugins[:Language]
    loadDaijirin
  end

  def beforeUnload
    @l = nil
    @hash = nil
    @resultLists = nil
    @resultListMarks = nil
    @enquiryTimes = nil
  end

  def expireLookups
    now = Time.now.to_i
    @enquiryTimes.each_pair { |k, v| resetResults(k) if now - v > @expire }
  end

  def resetResults(enquirer)
    @resultLists.delete(enquirer)
    @resultListMarks.delete(enquirer)
    @enquiryTimes.delete(enquirer)
  end

  def on_privmsg(msg)
    expireLookups
    case msg.botcommand
    when :dj
      return unless msg.tail
      resetResults(msg.replyTo)
      replyToEnquirer(lookup(@l.kana(msg.tail), [:kanji, :kana]), msg)
    when :de
      return unless msg.tail
      resetResults(msg.replyTo)
      replyToEnquirer(lookup(msg.tail, [:english]), msg)
    when :dn
      if @resultListMarks[msg.replyTo]
        @resultListMarks[msg.replyTo] += @menusize
        replyToEnquirer(nil, msg)
      end
    else
      if lr = @resultLists[msg.replyTo]
        @enquiryTimes[msg.replyTo] = Time.now.to_i
        indexstr = msg.message[/^\s*[dD][0-9]+\s*$/]
        index = 0
        index = indexstr.gsub(/[dD]/,'').to_i if indexstr
        if index > 0 && index < lr.length + 1
          entry = lr[index - 1]
          do_reply(msg, entry) if entry
        end
      end
    end
  end

  def replyToEnquirer(lookupResult, msg)
    lr = lookupResult || @resultLists[msg.replyTo]
    @resultListMarks.delete(msg.replyTo) if lookupResult
    if lr
      @resultLists[msg.replyTo] = lr
      @enquiryTimes[msg.replyTo] = Time.now.to_i
      mark = @resultListMarks[msg.replyTo] ||= 0
      if mark < lr.length then
        if lr.length == 1 then
          @resultListMarks[msg.replyTo] = 1
          do_reply(msg, lr.first)
        else
          menuItems = lr[mark, @menusize]
          readingsDisplay = (menuItems.length > 1) && (menuItems.collect { |e| e.kana }.uniq.length == 1)
          if menuItems
            menu = menuItems.map.with_index { |e, i| "#{i + mark + 1} #{readingsDisplay ? e.kana : e.kanji}" }.join(' | ')
            menu = "#{lr.length} hits: " + menu if mark == 0
            menu += " [#{IRCMessage::BotCommandPrefix}n for next]" if (mark + @menusize) < lr.length
            msg.reply(menu)
          else
            @resultListMarks.delete(msg.replyTo)
          end
        end
      else
        msg.reply("No more hits.")
      end
    else
      msg.reply("No hit for '#{msg.tail}'.")
    end
  end

  def do_reply(msg, entry)
    entry.to_lines.each do |line|
      msg.reply(line)
    end
  end

  # Looks up a word in specified hash(es) and returns the result as an array of entries
  def lookup(word, hashes)
    lookupResult = []
    hashes.each do |h|
      entryArray = @hash[h][word]
      lookupResult |= entryArray if entryArray
    end
    return if lookupResult.empty?
    sortResult(lookupResult)
    lookupResult
  end

  # Looks up keywords in the keyword hash.
  # Specified argument is a string of one or more keywords.
  # Returns the intersection of the results for each keyword.
  def keywordLookup(word)
    lookupResult = nil
    keywords = word.downcase.gsub(/[^a-z0-9 ]/, '').split(' ').uniq
    keywords.each do |k|
      return unless (entryArray = @hash[:english][k.to_sym])
      if lookupResult
        lookupResult &= entryArray
      else
        lookupResult = Array.new(entryArray)
      end
    end
    sortResult(lookupResult)
    lookupResult = nil if lookupResult.empty?
    lookupResult
  end

  def sortResult(lr)
    lr.sort_by!{|e| e.sort_key} if lr
  end

  def loadDaijirin
    @resultLists = {}
    @resultListMarks = {}
    @enquiryTimes = {}
    File.open("#{(File.dirname __FILE__)}/daijirin.marshal", 'r') do |io|
      @hash = Marshal.load(io)
    end
  end
end
