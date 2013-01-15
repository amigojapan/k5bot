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
  $mecab = MeCab::Tagger.new("-Ohasen2")
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

        #p "entries: #{@all_entries.size} decomposed: #@decomposed."

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
    #p "r: #{r}"
    r = r ? r.keys.to_a : []
    #p "jap: #{japanese}"
    r2 = process_with_mecab("膜#{japanese}")
    #p "r2: #{r2}"
    if r2
      r2.shift
      r2 = r2.map{|_,y| hiragana(y)}.join
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
    #p "#{original}: #{decomposition}"
    decomposition.map do |x, y|
      [x, original.slice!(0, y.size)]
    end
  end

  def gather_reading(decomposition)
    decomposition.map { |_, y| y }.join
  end

  def gather_reading_normalized(decomposition)
    decomposition.map { |_, y| hiragana(y) }
  end

  def get_reading_decomposition(japanese, reading)
    if japanese.size <= 1
      #put_to_decomposition_cache(japanese, reading, [reading])
      return [reading]
    end
    decomposition = @mecab_cache[japanese]
    decomposition = decomposition[reading] if decomposition
    if decomposition
      decomposition = decomposition
      #decomposition = japanese.each_char.zip(decomposition)
    else
      decomposition = process_with_mecab(japanese)
    end
    unless decomposition
      @decomposed[:parse_fail]+=1
      return
    end

    unless reading_equal?(reading, gather_reading(decomposition))
      #reading_norm = hiragana(reading)
      #decomposition_norm = gather_reading_normalized(decomposition)

      known_start = []
      original = reading.dup

      while decomposition.size > 1
        x, y = decomposition.shift
        oh = hiragana(original)
        yh = hiragana(y)
        unless oh.size > yh.size && oh.start_with?(yh)
          decomposition.unshift([x, y])
          break
        end
        known_start << [x, original.slice!(0, y.size)]
      end

      known_end = []
      while decomposition.size > 1
        x, y = decomposition.pop
        oh = hiragana(original)
        yh = hiragana(y)
        unless oh.size > yh.size && oh.end_with?(yh)
          decomposition.push([x, y])
          break
        end
        known_end.unshift([x, original.slice!(-y.size..-1)])
      end

      if decomposition.size > 1
        @decomposed[:failed_reading]+=1
        return
      else
        #if decomposition[0][0].size > 1
        #  @decomposed[:partially_failed_reading]+=1
        #  return
        #else
          #@decomposed[:restorable_reading]+=1
          decomposition = (known_start << [decomposition[0][0], original]) + known_end
        #end
      end
      #p "entry mismatch: jap: #{japanese}; read: #{reading_norm}; decomp: #{decomposition_reading.join}"
      #return
    end

    decomposition = transplant_original(reading, decomposition)

    subdec = decomposition.map do |x, y|
      if (x.size <= 1) || (x.eql?(y))
        [[x, y]]
      else
        sub = subsearch(x, y)
        return unless sub
        sub
      end
    end
    subdec.flatten!(1)
    result = subdec

=begin
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
      result = decomposition
    end
=end

    put_to_decomposition_cache(japanese, reading, result)

    #sub_cases = japanese.each_char.zip(result)
    sub_cases = result
    sub_cases.each do |j, r|
      put_to_decomposition_cache(j, r, [[j, r]])
    end

    result
  end

  def subsearch(japanese, reading)
    #if decomposition.size < japanese.size
      if japanese.size > 2
        @decomposed[:unguessed_else]+=1
        @decomposed[japanese.size]+=1
        p "j: #{japanese}; r: #{reading}"
        return
      end
      r = japanese.each_char.map do |x|
        #p "x: #{x}"
        lg = lookup_reading(x)
        #p "lg: #{lg}"
        lg.select do |y|
          #p y
          y.size > 0 && y.size < reading.size
        end
      end
      r0 = r.shift

      decomposition_reading = nil
      if japanese.size <= 2
        known_part = r0.find do |x|
          reading.start_with?(x)
        end

        if known_part
          inferred = reading[known_part.size..-1]
          decomposition_reading = [known_part, inferred]
        else
          known_part = r[-1].find do |x|
            reading.end_with?(x)
          end
          if known_part
            inferred = reading[0..-known_part.size-1]
            decomposition_reading = [inferred, known_part]
          end
        end
      end

      unless decomposition_reading
        reads = r0.product(*r)
        decomposition_reading = reads.find do |x|
          reading_equal?(reading, x.join)
        end
      end

      unless decomposition_reading
        @decomposed[:unguessed_two]+=1
        p "j: #{japanese}; r: #{reading}"
        #@decomposed[:unguessed]+=1
        #@decomposed[japanese.size]+=1
        return
      end

      decomposition = japanese.each_char.zip(decomposition_reading)

      result = transplant_original(reading, decomposition)
    #else
    #  result = decomposition
    #end
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
      return if line.start_with?('UNK')

      # "なっ\tナッ\tなる\t動詞-自立\t五段・ラ行\t連用タ接続"
      fields = line.split("\t")
      fields.map! {|f| f.strip}

      part = fields.shift
      reading = fields.shift

      unless is_katakana?(reading)
        return
      end

      result << [part, reading]
    end

    result
  end

  def is_katakana?(text)
    # 30A0-30FF katakana
    # FF61-FF9D half-width katakana
    # 31F0-31FF katakana phonetic extensions
    #
    # Source: http://www.unicode.org/charts/
    !!(text =~ /^[\u30A0-\u30FF\uFF61-\uFF9D\u31F0-\u31FF]+$/)
  end

  def is_kanji?(text)
    # 3040-309F hiragana
    # 30A0-30FF katakana
    # 4E00-9FC2 kanji
    # FF61-FF9D half-width katakana
    # 31F0-31FF katakana phonetic extensions
    # 3000-303F CJK punctuation
    #
    # Source: http://www.unicode.org/charts/
    !!(text =~ /^[\u3040-\u309F\u30A0-\u30FF\u4E00-\u9FC2\uFF61-\uFF9D\u31F0-\u31FF\u3000-\u303F]+$/)
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
