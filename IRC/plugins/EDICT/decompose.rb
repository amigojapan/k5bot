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

    @decomposition_statistics = Hash.new() {|_,_| 0}

    @mecab_readings = Hash.new() do |_, kanji|
      # Try to guess on-reading by combining given kanji with 膜 (random kanji)
      r2 = process_with_mecab("膜#{kanji}")
      if r2
        # and then stripping off reading of 膜.
        r2.shift
        # Now there must be just one [japanese, reading] pair,
        # but we're too lazy to check that.
        # Strip off japanese, and convert reading to hiragana.
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
    @decomposition_cache = File.open(@decomposition_file, 'r') do |io|
      Marshal.load(io)
    end rescue {}

    excl = File.open(@exclusion_file, 'r') do |io|
      Marshal.load(io)
    end rescue {}
    @decomposition_exclusions = Set.new()
    excl.each_pair do |japanese, reading_array|
      reading_array.each do |reading|
        @decomposition_exclusions.add([japanese, reading])
      end
    end
  end

  def save_mecab_cache
    File.open(@decomposition_file, 'w') do |io|
      Marshal.dump(@decomposition_cache, io)
    end
  end

  def decompose
    @hash[:all].each_with_index do |entry, index|
      combo = entry.japanese.eql?(entry.reading) || get_reading_decomposition(entry.japanese, entry.reading)
      @decomposition_statistics[:total]+=1 if combo

      if index % 1000 == 0
        p "Entries: #{index}; Statistics: #@decomposition_statistics"
      end
    end

    puts "Entries: #{@hash[:all].size}; Statistics: #@decomposition_statistics"
  end

  def lookup_reading(japanese)
    # Get known readings from cache.
    r = @decomposition_cache[japanese]
    r = r ? r.keys.to_a : []
    # Throw in mecab-suggested reading for a good measure.
    r2 = @mecab_readings[japanese]
    r |= r2 if r2
    r
  end

  def reading_equal?(r1, r2)
    hiragana(r1).eql?(hiragana(r2))
  end

  def transplant_original_reading(original, decomposition)
    original = original.dup
    decomposition.map do |x, y|
      [x, original.slice!(0, y.size)]
    end
  end

  def gather_reading(decomposition)
    decomposition.map { |_, y| y }.join
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
    case japanese.size
    when 0
      raise "Bug! We should be never asked for reading decomposition of an empty word."
    when 1
      # Given japanese word is just one symbol, there's nothing to decompose.
      result = [reading]
      put_to_decomposition_cache(japanese, reading, result)
      return result
    else
      if reading_equal?(japanese, reading)
        # This is a kana/kana entry, or similar, so
        # there's char-by-char correspondence between readings.
        result = reading.each_char.to_a
        put_to_decomposition_cache(japanese, reading, result)
        return result
      end
    end

    decomposition = process_with_mecab(japanese)
    unless decomposition
      @decomposition_statistics[:parse_fail]+=1
      return
    end

    unless reading_equal?(reading, gather_reading(decomposition))
      # Mecab-suggested decomposition doesn't match "#{reading}",
      # which is assumed to be correct. Let's attempt to restore
      # the reading, if there's only one wrong [japanese, reading] pair.

      known_start = []
      reading_guess = reading.dup

      while decomposition.size > 1
        x, y = decomposition.shift
        oh = hiragana(reading_guess)
        yh = hiragana(y)
        unless oh.size > yh.size && oh.start_with?(yh)
          decomposition.unshift([x, y])
          break
        end
        known_start << [x, reading_guess.slice!(0, y.size)]
      end

      known_end = []
      while decomposition.size > 1
        x, y = decomposition.pop
        oh = hiragana(reading_guess)
        yh = hiragana(y)
        unless oh.size > yh.size && oh.end_with?(yh)
          decomposition.push([x, y])
          break
        end
        known_end.unshift([x, reading_guess.slice!(-y.size..-1)])
      end

      if decomposition.size > 1
        # Stripping matching readings didn't result in
        # a single invalid pair. Give up.
        @decomposition_statistics[:failed_reading]+=1
        return
      end

      # We reduced mismatch to a single [japanese, wrong_reading] pair.
      # Extract japanese.
      japanese_guess = decomposition[0][0]

      # There are tricky cases, when such guessing is dangerous and produces
      # wrong pair. Let's try to avoid that.

      # This is for cases, when mismatch results in assigning "new reading" to a kana.
      # i.e. ["い", "がい"]. The amount of mess this may cause is beyond imagination.
      if is_all_kana?(japanese_guess) && !reading_equal?(japanese_guess, reading)
        @decomposition_statistics[:dangerously_failed_reading]+=1
        return
      end
      if sanity_check_failure?(japanese_guess, reading)
        @decomposition_statistics[:reading_sanity_fail]+=1
        return
      end

      # Everything seems to be ok. Reconstruct decomposition with corrected pair.
      decomposition = (known_start << [japanese_guess, reading_guess]) + known_end
    end

    # Mecab produces katakana reading. Replace that with what's in "#{reading}".
    decomposition = transplant_original_reading(reading, decomposition)

    # Mecab has only split up to word/stem detail.
    # Let's try to sub-split each of them on per-character basis.
    sub_decomposition = decomposition.map do |x, y|
      if x.size <= 1
        # Nothing to split
        [[x, y]]
      elsif reading_equal?(x, y)
        # This is a kana/kana entry, or similar, so
        # there's char-by-char correspondence between readings.
        x.each_char.zip(reading.each_char)
      else
        sub = sub_decompose_reading(x, y)
        unless sub
          @decomposition_statistics[:unbreakable]+=1
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
          case sub.size
          when 0
            puts "guessed: j: #{japanese} r: #{reading} a: #{bub}"
            @decomposition_statistics[:ambiguous_guessed]+=1
            return
          when 1
            puts "restored: j: #{japanese} r: #{reading} a: #{bub}"
            @decomposition_statistics[:ambiguous_restored]+=1
          else
            puts "unguessed: j: #{japanese} r: #{reading} a: #{bub}"
            @decomposition_statistics[:ambiguous_unguessed]+=1
            return
          end
        end

        sub[0]
      end

    end
    result = sub_decomposition.flatten(1)

    # Put all guessed separate reading pairs into cache,
    # to help us with decomposing further entries (see lookup_reading()).
    result.each do |j, r|
      put_to_decomposition_cache(j, r, [r])
    end

    compacted = compact(result)
    put_to_decomposition_cache(japanese, reading, compacted)

    compacted
  end

  # Checks some basic things that should be true of any reading pair
  def sanity_check_failure?(j, r)
    c = r[0]
    if c.match(/[んっょゅゃ]/)
      # Reading can start with those chars,
      # only if japanese starts with the same char.
      return true unless reading_equal?(c, j[0])
    end
    # Check user-defined rules.
    @decomposition_exclusions.include?([j, r])
  end

  def sub_decompose_reading(japanese, reading)
    if japanese.size <= 0
      # if we exhausted japanese before reading - give up,
      # otherwise it's simultaneous exhaustion, return new decomposition root.
      return reading.size>0 ? nil : [Decomposition.new()]
    end
    return [Decomposition.new([[japanese, reading]])] if reading_equal?(japanese, reading)
    return nil if is_all_kana?(japanese) # japanese is fully kana, but reading doesn't match. failure.

    last_take = japanese.size == 1
    allowed_take = last_take ? reading.size + 1 : reading.size

    head = japanese[0]

    lg = lookup_reading(head)
    lg = lg.select do |y|
      y.size > 0 && y.size < allowed_take && reading.start_with?(y)
    end

    return sub_decompose_reading_tail(japanese, reading) if lg.empty?

    tail = japanese[1..-1]

    result = lg.map do |guess|
      sub = sub_decompose_reading(tail, reading[guess.size..-1])
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

  def sub_decompose_reading_tail(japanese, reading)
    if japanese.size <= 0
      # if we exhausted japanese before reading - give up,
      # otherwise it's simultaneous exhaustion, return new decomposition root.
      return reading.size>0 ? nil : [Decomposition.new()]
    end
    return [Decomposition.new([[japanese, reading]])] if reading_equal?(japanese, reading)
    return nil if is_all_kana?(japanese) # japanese is fully, kana but reading doesn't match. failure.

    last_take = japanese.size == 1
    allowed_take = last_take ? reading.size + 1 : reading.size

    head = japanese[-1]

    lg = lookup_reading(head)
    lg = lg.select do |y|
      y.size > 0 && y.size < allowed_take && reading.end_with?(y)
    end

    if lg.empty?
      return if japanese.size > 1
      # So we have only one kanji, let's assume, that
      # what remained of reading belongs to it.
      result = Decomposition.new([[japanese, reading]])
      # We mark such entry specifically, to be able to filter it out,
      # in case we have better candidates.
      result.guessed = true
      return [result]
    end

    tail = japanese[0..-2]

    result = lg.map do |guess|
      sub = sub_decompose_reading_tail(tail, reading[0..-guess.size-1])
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
    (@decomposition_cache[japanese] ||= {})[reading] = result
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

    remerge_non_japanese(result)
  end

  # Some things can't have correct reading correspondence.
  # E.g. naively, 1 would be assigned "じゅう" and "ひゃく" readings.
  # This procedure merges such things in clusters, that can have valid readings.
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

  def is_all_katakana?(text)
    # 30A0-30FF katakana
    # FF61-FF9D half-width katakana
    # 31F0-31FF katakana phonetic extensions
    #
    # Source: http://www.unicode.org/charts/
    !!(text =~ /^[\u30A0-\u30FF\uFF61-\uFF9D\u31F0-\u31FF]+$/)
  end

  def is_all_kana?(text)
    # 3040-309F hiragana
    # 30A0-30FF katakana
    # FF61-FF9D half-width katakana
    # 31F0-31FF katakana phonetic extensions
    #
    # Source: http://www.unicode.org/charts/
    !!(text =~ /^[\u3040-\u309F\u30A0-\u30FF\uFF61-\uFF9D\u31F0-\u31FF]+$/)
  end

  def is_all_japanese?(text)
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
