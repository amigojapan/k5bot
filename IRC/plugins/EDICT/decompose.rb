#!/usr/bin/env ruby
# encoding: utf-8
# This file is part of the K5 bot project.
# See files README.md and COPYING for copyright and licensing information.

# EDICT converter
#
# Converts the EDICT file to a marshalled hash, readable by the EDICT plugin.
# When there are changes to EDICTEntry or EDICT is updated, run this script
# to re-index (./convert.rb), then reload the EDICT plugin (!load EDICT).

$VERBOSE = true

require 'iconv'
require 'yaml'
require_relative 'EDICTEntry'

begin
require 'MeCab' # mecab ruby binding
  $mecab = MeCab::Tagger.new("-Ochasen2")
rescue Exception
  $mecab = nil
end

class EDICTConverter
  attr_reader :hash

  def initialize(edict_file, decomposition_file)
    @edict_file = edict_file
    @decomposition_file = decomposition_file
    @hash = {}
    @hash[:japanese] = {}
    @hash[:readings] = {}
    @hash[:keywords] = {}
    @all_entries = []
    @hash[:all] = @all_entries

    # Duplicated two lines from ../Language/Language.rb
    @kata2hira = YAML.load_file("../Language/kata2hira.yaml") rescue nil
    @katakana = @kata2hira.keys.sort_by{|x| -x.length}

    @decomposed = Hash.new() {|h,k| 0}
  end

  def load_mecab_cache
    @mecab_cache = File.open(@decomposition_file, 'r') do |io|
      Marshal.load(io)
    end rescue {}
    @mecab_cache_dirty = @mecab_cache.empty?
  end

  def save_mecab_cache
    return unless @mecab_cache_dirty
    File.open(@decomposition_file, 'w') do |io|
      Marshal.dump(@mecab_cache, io)
    end
  end

  def read
    load_mecab_cache

    File.open(@edict_file, 'r') do |io|
      io.each_line do |l|
        entry = EDICTEntry.new(Iconv.conv('UTF-8', 'EUC-JP', l).strip)

        combo = entry.japanese.eql?(entry.reading) || get_reading_decomposition(entry.japanese, entry.reading)
        @decomposed[:total]+=1 if combo

        p "entries: #{@all_entries.size} decomposed: #@decomposed."

        @all_entries << entry
        (@hash[:japanese][entry.japanese] ||= []) << entry
        (@hash[:readings][hiragana(entry.reading)] ||= []) << entry
        entry.keywords.each do |k|
          (@hash[:keywords][k] ||= []) << entry
        end

      end
    end

    p "entries: #{@all_entries.size} decomposed: #@decomposed. saving result cache..."

    save_mecab_cache
  end

  def sort
    count = 0
    @all_entries.sort_by!{|e| [ (e.common? ? -1 : 1), (!e.xrated? ? -1 : 1), (!e.vulgar? ? -1 : 1), e.reading, e.keywords.size, e.japanese.length]}
    @all_entries.each do |e|
      e.sortKey = count
      count += 1
    end
  end

  # Duplicated method from ../Language/Language.rb
  def hiragana(katakana)
    return katakana unless katakana =~ /[\u30A0-\u30FF\uFF61-\uFF9D\u31F0-\u31FF]/
    hiragana = katakana.dup
    @katakana.each{|k| hiragana.gsub!(k, @kata2hira[k])}
    hiragana
  end

  def nl(a, b)
    a[b] if a
  end

  def lookup_reading(japanese)
    r = @mecab_cache[japanese]
    r = r ? r.keys.to_a : []
    r2 = process_with_mecab("膜#{japanese}")
    if r2
      r2.shift
      r2 = r2.map{|_,y| y}.join
      r |= [r2]
    end
    r
  end

  def reading_equal?(r1, r2)
    hiragana(r1).eql?(hiragana(r2))
  end

  def reading_transplant?(r1, r2)
    hiragana(r1).eql?(hiragana(r2))
  end

  def transplant_original(original, decomposition)
    original = original.dup
    decomposition.map do |x|
      original.slice!(0, x.size)
    end
  end

  def get_reading_decomposition(japanese, reading)
    if japanese.size <= 1
      put_to_decomposition_cache(japanese, reading, [reading])
      return [reading]
    end
    decomposition = @mecab_cache[japanese]
    decomposition = decomposition[reading] if decomposition
    decomposition = process_with_mecab(japanese) unless decomposition
    unless decomposition
      @decomposed[:parse_fail]+=1
      return
    end

    if decomposition.size < japanese.size
      if japanese.size > 2
        @decomposed[japanese.size]+=1
        return
      end
      r1 = lookup_reading(japanese[0])
      r2 = lookup_reading(japanese[1])
      reads = r1.product(r2)

      decomposition_reading = reads.find do |x|
        reading_equal?(reading, x.join)
      end

      unless decomposition_reading
        @decomposed[:unguessed_two]+=1
        return
      end
      result = transplant_original(reading, decomposition_reading)
    else
      decomposition_reading = decomposition.map { |_, y| y }

      if reading_equal?(reading, decomposition_reading.join)
        result = transplant_original(reading, decomposition_reading)
        #subdec = result.map do |x, y|
        #  x.size > 1 ? get_reading_decomposition(x, y) : [[x, y]]
        #end
        #subdec.flatten!(1)
        #result = subdec
      else
        @decomposed[:failed_reading]+=1
        #p "entry mismatch: jap: #{japanese}; read: #{reading_norm}; decomp: #{decomposition_reading.join}"
        return
      end
    end

    put_to_decomposition_cache(japanese, reading, result)

    sub_cases = japanese.each_char.zip(result)
    sub_cases.each do |j, r|
      put_to_decomposition_cache(j, r, [r])
    end

    result
  end

  def put_to_decomposition_cache(japanese, reading, result)
    (@mecab_cache[japanese] ||= {})[reading] = result
    @mecab_cache_dirty = true
  end

  def process_with_mecab(text)
    return unless $mecab

    output = $mecab.parse(text).force_encoding('UTF-8')

    result = []

    output.each_line.map do |line|
      break if line.start_with?('EOS')

      # "なっ\tナッ\tなる\t動詞-自立\t五段・ラ行\t連用タ接続"
      fields = line.split("\t")
      fields.map! {|f| f.strip}

      part = fields.shift
      reading = fields.shift

      result << [part, reading]
    end

    result
  end
end

def marshal_dict(dict)
  ec = EDICTConverter.new("#{(File.dirname __FILE__)}/#{dict}", "#{(File.dirname __FILE__)}/#{dict}_mecab.marshal")

  print "Indexing #{dict.upcase}..."
  ec.read
  puts "done."

  print "Sorting #{dict.upcase}..."
  ec.sort
  puts "done."

  print "Marshalling #{dict.upcase}..."
  File.open("#{(File.dirname __FILE__)}/#{dict}.marshal", 'w') do |io|
    Marshal.dump(ec.hash, io)
  end
  puts "done."
end

marshal_dict('edict')
#marshal_dict('enamdict')
