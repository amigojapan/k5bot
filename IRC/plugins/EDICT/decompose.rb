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

require 'yaml'
require 'MeCab' # mecab ruby binding
require 'set'

require_relative '../../IRCPluginManager'

require_relative 'EDICTEntry'

$mecab = MeCab::Tagger.new("-Ochasen2")

class TmpPluginManager < IRCPluginManager
  def find_config_entry(name)
    name = name.to_sym
    [name, {}]
  end
end

plugin_manager = TmpPluginManager.new()

raise "Can't load Language plugin" unless plugin_manager.load_plugin(:Language)

$language = plugin_manager.plugins[:Language]

class Decomposition < Array
  attr_accessor :guessed
end

class JapaneseReadingDecomposer
  attr_reader :hash

  def initialize(edict_file, decomposition_file, exclusion_file)
    @edict_file = edict_file
    @decomposition_file = decomposition_file
    @exclusion_file = exclusion_file

    @decomposed = Hash.new() {|h,k| 0}

    @mecab_readings = Hash.new() do |h, kanji|
      r2 = process_with_mecab("膜#{kanji}")
      if r2
        r2.shift
        r2.map!{|_,y| hiragana(y)}
        r2
      end
    end
  end

  def load_dict
    @hash = File.open(@edict_file, 'r') do |io|
      Marshal.load(io)
    end
  end

  def load_mecab_cache
    @mecab_cache = File.open(@decomposition_file, 'r') do |io|
      Marshal.load(io)
    end rescue {}
    #@mecab_cache = {}
    excl = File.open(@exclusion_file, 'r') do |io|
      Marshal.load(io)
    end rescue {}
    @mecab_exclusions = Set.new()
    excl.each_pair do |japanese, reading_array|
      reading_array.each do |reading|
        @mecab_exclusions.add([japanese, reading])
      end
    end

    @mecab_cache_origin = {}
    @mecab_cache_dirty = @mecab_cache.empty?
  end

  def save_mecab_cache
    return unless @mecab_cache_dirty
    File.open(@decomposition_file, 'w') do |io|
      Marshal.dump(@mecab_cache, io)
    end
  end

  def decompose
    @hash[:all].each_with_index do |entry, index|
      combo = entry.japanese.eql?(entry.reading) || get_reading_decomposition(entry.japanese, entry.reading)
      @decomposed[:total]+=1 if combo

      #p "entries: #{index}; Decomposed: #@decomposed"

      #process_with_mecab(entry.japanese)
    end

    puts "Entries: #{@hash[:all].size}; Decomposed: #@decomposed"
  end

  def nl(a, b)
    a[b] if a
  end

  def lookup_reading(japanese)
    r = @mecab_cache[japanese]
    #p "r: #{r}"
    r = r ? r.keys.to_a : []
    #p "jap: #{japanese}"
    r2 = @mecab_readings[japanese]
    r |= r2 if r2
    #p "r2: #{r2}"
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

  def expand(japanese, decomposition)
    current = nil
    result = []
    decomposition.each_with_index do |reading, i|
      if reading
        current = ['', reading]
        result << current
      end
      current[0] << japanese[i]
    end

    result
  end

  def compact(decomposition)
    idx = 0
    result = []
    decomposition.each do |japanese, reading|
      result[idx] = reading
      idx += japanese.size
    end

    result
  end

  def get_reading_decomposition(japanese, reading)
    #p "j: #{japanese} r: #{reading}"
    case japanese.size
    when 0
      raise "Fuckup"
    when 1
      result = [reading]
      put_to_decomposition_cache(japanese, reading, result)
      return result
    else
      if reading_equal?(japanese, reading)
        result = reading.each_char.to_a
        put_to_decomposition_cache(japanese, reading, result)
        return result
      end
    end
    #decomposition = @mecab_cache[japanese]
    #decomposition = decomposition[reading] if decomposition
    #if decomposition
    #  #decomposition = expand(japanese, decomposition)
    #  return expand(japanese, decomposition)
    #else
      decomposition = process_with_mecab(japanese)
    #end
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
          #decomposition = (known_start << [decomposition[0][0], original]) + known_end
        #end

        guess = decomposition[0][0]

        if is_kana?(guess) && !reading_equal?(guess, reading)
          @decomposed[:dangerously_failed_reading]+=1
          return
        end
        if sanity_check_failure?(guess, reading)
          @decomposed[:reading_sanity_fail]+=1
          return
        end

        decomposition = (known_start << [guess, original]) + known_end
      end
      #p "entry mismatch: jap: #{japanese}; read: #{reading_norm}; decomp: #{decomposition_reading.join}"
      #return
    end

    #return if decomposition.size <=1

    decomposition = transplant_original(reading, decomposition)

    subdec = decomposition.map do |x, y|
      if (x.size <= 1) || reading_equal?(x, y)
        [[x, y]]
      else
        sub = subsearch3(x, y)
        unless sub
          @decomposed[:unbreakable]+=1
          return
        end
        if sub.size > 1
          bub = sub.dup
          sub.delete_if do |sub_decomp|
            sub_decomp.any? do |j, r|
              sanity_check_failure?(j, r)
            end
          end
          if sub.size > 1
            sub.delete_if do |sub_decomp|
              sub_decomp.guessed
            end
          end
          #subsearch3(x, y)
          case sub.size
          when 0
            puts "guessed: j: #{japanese} r: #{reading} a: #{bub}"
            @decomposed[:ambiguous_guessed]+=1
            return
          when 1
            puts "restored: j: #{japanese} r: #{reading} a: #{bub}"
            @decomposed[:ambiguous_restored]+=1
          else
            puts "unguessed: j: #{japanese} r: #{reading} a: #{bub}"
            @decomposed[:ambiguous_unguessed]+=1
            return
          end
        end

        sub[0]
      end

#      sub = get_reading_decomposition(x, y)
#      return unless sub
#      expand(x, sub)
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
    compacted = compact(result)
    put_to_decomposition_cache(japanese, reading, compacted)

    #sub_cases = japanese.each_char.zip(result)
    sub_cases = result
    sub_cases.each do |j, r|
      put_to_decomposition_cache(j, r, [r])
      put_to_decomposition_origin_cache(j, r, [[japanese, reading]])
    end

    result
  end

  def sanity_check_failure?(j, r)
    c = r[0]
    if c.match[/[んっょゅゃ]/]
      return true unless reading_equal?(c, j[0])
    end
    @mecab_exclusions.include?([j, r])
  end

  def subsearch2(japanese, reading)
    decomposition = @mecab_cache[japanese]
    decomposition = decomposition[reading] if decomposition
    return expand(japanese, decomposition) if decomposition

    @decomposed[:unguessed]+=1
    nil
  end

  def subsearch(japanese, reading)
    #if decomposition.size < japanese.size
      #if japanese.size > 2
      #  @decomposed[:unguessed_else]+=1
      #  @decomposed[japanese.size]+=1
      #  p "j: #{japanese}; r: #{reading}"
      #  return
      #end
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
      else

      end

      unless decomposition_reading
        reads = r0.product(*r)
        decomposition_reading = reads.find do |x|
          reading_equal?(reading, x.join)
        end
      end

      unless decomposition_reading
        @decomposed[:unguessed_two]+=1
        #p "j: #{japanese}; r: #{reading}"
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

  def subsearch3(japanese, reading)
    if japanese.size <= 0
      #return reading.size>0 ? [[[japanese, reading]]] : nil
      return reading.size>0 ? nil : [Decomposition.new()]
    end
    return [Decomposition.new([[japanese, reading]])] if reading_equal?(japanese, reading)
    return nil if is_kana?(japanese) # japanese is fully kana but reading doesn't match. failure.

    last_take = japanese.size == 1
    allowed_take = last_take ? reading.size + 1 : reading.size

    head = japanese[0]

    lg = lookup_reading(head)
    lg = lg.select do |y|
      y.size > 0 && y.size < allowed_take && reading.start_with?(y)
    end

    return subsearch4(japanese, reading) if lg.empty?

    tail = japanese[1..-1]

    result = lg.map do |guess|
      sub = subsearch3(tail, reading[guess.size..-1])
      next unless sub
      decomp = [head, guess]
      sub.each do |sub_decomp|
        sub_decomp.unshift(decomp)
      end
    end

    result.flatten!(1)
    result = result.select {|x| !x.nil?}

    result unless result.empty?
  end

  def subsearch4(japanese, reading)
    if japanese.size <= 0
      #return reading.size>0 ? [[[japanese, reading]]] : nil
      return reading.size>0 ? nil : [Decomposition.new()]
    end
    return [Decomposition.new([[japanese, reading]])] if reading_equal?(japanese, reading)
    return nil if is_kana?(japanese) # japanese is fully kana but reading doesn't match. failure.

    last_take = japanese.size == 1
    allowed_take = last_take ? reading.size + 1 : reading.size

    head = japanese[-1]

    lg = lookup_reading(head)
    lg = lg.select do |y|
      y.size > 0 && y.size < allowed_take && reading.end_with?(y)
    end

    if lg.empty?
      return if japanese.size > 1
      #p "Guess: j: #{japanese}; r: #{reading}"
      result = Decomposition.new([[japanese, reading]])
      result.guessed = true
      return [result]
    end

    tail = japanese[0..-2]

    result = lg.map do |guess|
      sub = subsearch4(tail, reading[0..-guess.size-1])
      next unless sub
      decomp = [head, guess]
      sub.each do |sub_decomp|
        sub_decomp.push(decomp)
      end
    end

    result.flatten!(1)
    result = result.select {|x| !x.nil?}

    result unless result.empty?
  end

  def put_to_decomposition_cache(japanese, reading, result)
    (@mecab_cache[japanese] ||= {})[reading] = result
    @mecab_cache_dirty = true
  end

  def put_to_decomposition_origin_cache(japanese, reading, result)
    (@mecab_cache_origin[japanese] ||= {})[reading] ||= []
    @mecab_cache_origin[japanese][reading] |= result
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

      #unless is_japanese?(part)
      #  print "#{part}\n"
      #end

      result << [part, reading]
    end

    remerge_non_japanese(result)
  end

  def remerge_non_japanese(decomposition)
    prev = nil
    decomposition.delete_if do |x|
      japanese, reading = x
      if japanese =~ /[0-9０１２３４５６７８９]/
        if prev
          prev[0] << japanese
          prev[1] << reading
          true
        else
          prev = x
          false
        end
      else
        prev = nil
        false
      end
    end
  end

  def hiragana(text)
    $language.hiragana(text)
  end

  def is_katakana?(text)
    # 30A0-30FF katakana
    # FF61-FF9D half-width katakana
    # 31F0-31FF katakana phonetic extensions
    #
    # Source: http://www.unicode.org/charts/
    !!(text =~ /^[\u30A0-\u30FF\uFF61-\uFF9D\u31F0-\u31FF]+$/)
  end

  def is_kana?(text)
    # 3040-309F hiragana
    # 30A0-30FF katakana
    # FF61-FF9D half-width katakana
    # 31F0-31FF katakana phonetic extensions
    #
    # Source: http://www.unicode.org/charts/
    !!(text =~ /^[\u3040-\u309F\u30A0-\u30FF\uFF61-\uFF9D\u31F0-\u31FF]+$/)
  end

  def is_japanese?(text)
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
  ec = JapaneseReadingDecomposer.new("#{(File.dirname __FILE__)}/#{dict}.marshal", "#{(File.dirname __FILE__)}/#{dict}_mecab.marshal", "#{(File.dirname __FILE__)}/exclusions.yaml")

  print "Loading #{dict.upcase}..."
  ec.load_dict
  puts "done."

  print "Loading #{dict.upcase} decomposition cache..."
  ec.load_mecab_cache
  puts "done."

  print "Decomposing #{dict.upcase}..."
  ec.decompose
  puts "done."

  print "Saving #{dict.upcase} decomposition cache..."
  ec.save_mecab_cache
  puts "done."
end

marshal_dict('edict')
#marshal_dict('enamdict')
