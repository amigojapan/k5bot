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
raise "Can't load KANJIDIC2 plugin" unless plugin_manager.load_plugin(:KANJIDIC2)

$language = plugin_manager.plugins[:Language]
$kanjidic = plugin_manager.plugins[:KANJIDIC2]

class Decomposition < Array
  attr_accessor :guessed
end

class JapaneseReadingDecomposer
  attr_reader :hash

  def initialize(edict_file, decomposition_file, exclusion_file)
    @edict_file = edict_file
    @decomposition_file = decomposition_file
    @exclusion_file = exclusion_file
    @interactive = false

    @mecab_readings = Hash.new() do |_, kanji|
      r1 = $kanjidic.get_japanese_readings(kanji)
      if r1
        r1.map!{|y| hiragana(y)}
      end

      # Try to guess on-reading by combining given kanji with 膜 (random kanji)
      r2 = process_with_mecab("膜#{kanji}")
      if r2
        # and then stripping off reading of 膜.
        r2.shift
        # Now there must be just one [japanese, reading] pair,
        # but we're too lazy to check that.
        # Strip off japanese, and convert reading to hiragana.
        r2.map!{|_,y| hiragana(y)}
      end

      if r1
        r1 | (r2 || [])
      else
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
  end

  def load_decomposition_exclusions
    @decomposition_exclusions = File.open(@exclusion_file, 'r') do |io|
      YAML.load(io)
    end rescue {}
  end

  def put_decomposition_exclusion(japanese, reading, alternatives)
    k = @decomposition_exclusions[japanese] ||= {}
    k[reading] ||= []
    k[reading] |= [alternatives]
  end

  def save_mecab_cache
    File.open(@decomposition_file, 'w') do |io|
      Marshal.dump(@decomposition_cache, io)
    end
  end

  def save_decomposition_exclusions
    File.open(@exclusion_file, 'w') do |io|
      YAML.dump(@decomposition_exclusions, io)
    end
  end

  def sort_decomp_stats(stats)
    stats = stats.each_pair.to_a
    #stats.sort_by! {|_, val| -val }
    stats.sort_by! {|k, v| [-v, k.instance_of?(String) ? 1 : 0]}
    Hash[stats]
  end

  def decompose

    working_set = @hash[:all].each_with_index.to_a
    old_stats = nil

    loop.each do

      @decomposition_statistics = Hash.new() {|_,_| 0}
      cnt = 0
      working_set.delete_if do |entry, index|
        combo = entry.japanese.eql?(entry.reading) || get_reading_decomposition(entry.japanese, entry.reading)
        @decomposition_statistics[:total]+=1 if combo

        if cnt % 1000 == 0
          puts "Entry: #{index}; Statistics: #{sort_decomp_stats(@decomposition_statistics)}"
        end

        cnt+=1

        combo
      end

      puts "Entries completed: #{@hash[:all].size-working_set.size}; Entries processed: #{cnt}; Statistics: #{sort_decomp_stats(@decomposition_statistics)}"

      if @decomposition_statistics.eql?(old_stats)
        if @interactive
          break
        end
        @interactive = true
      else
        @interactive = false
      end

      old_stats = @decomposition_statistics
    end

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
      decomposition = try_restoring_decomposition(decomposition, japanese, reading)
      unless decomposition
        @decomposition_statistics[:decomposition_unrestorable]+=1
        return
      end
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
        sub = x.each_char.zip(y.each_char)
        sub.each do |j,r|
          unless reading_equal?(j,r)
            p "wrong! #{x}, #{y}"
          end
        end
      else
        sub = sub_decompose_reading(x, y)
        unless sub
          @decomposition_statistics[:unbreakable]+=1
          return
        end
        if sub.size > 1
          sub_tmp_copy = sub.dup
          begin
            sub.delete_if do |sub_decomp|
              decomp_sanity_check_failure?(sub_decomp)
            end
            if sub.size > 1
              sub.delete_if do |sub_decomp|
                sub_decomp.guessed
              end
            end
            case sub.size
            when 0
              raise "Retry disambiguation!" if fill_disambiguation_candidates(sub_tmp_copy, japanese, reading, 'AG;')
              @decomposition_statistics[:ambiguous_guessed]+=1
              return
            when 1
              @decomposition_statistics[:ambiguous_restored]+=1
            else
              raise "Retry disambiguation!" if fill_disambiguation_candidates(sub, japanese, reading, 'AU;')
              @decomposition_statistics[:ambiguous_unguessed]+=1
              return
            end
          rescue
            # retry disambiguation, restore unfiltered choices
            sub = sub_tmp_copy
            retry
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

  def try_restoring_decomposition(decomposition, japanese, reading)
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
      return [[japanese, reading]]
    end

    # We reduced mismatch to a single [japanese, wrong_reading] pair.
    # Extract japanese.
    japanese_guess = decomposition[0][0]

    # There are tricky cases, when such guessing is dangerous and produces
    # wrong pair. Let's try to avoid that.

    # This is for cases, when mismatch results in assigning "new reading" to a kana.
    # i.e. ["い", "がい"]. The amount of mess this may cause is beyond imagination.
    if is_all_kana?(japanese_guess) && !reading_equal?(japanese_guess, reading_guess)
      @decomposition_statistics[:dangerously_failed_reading]+=1
      return [[japanese, reading]]
    end

    decomp = (known_start << [japanese_guess, reading_guess]) + known_end

    #if sanity_check_failure?(japanese_guess, reading_guess)
    if decomp_sanity_check_failure?(decomp)
      @decomposition_statistics[:reading_sanity_fail]+=1
      return [[japanese, reading]]
    end

    # Everything seems to be ok. Reconstruct decomposition with corrected pair.
    decomp
  end

  def remember_problem(alternatives)
    #alternatives[0].each do |j, r|
    #  @decomposition_statistics[j] +=1
    #end
    merged = merge_ambiguities(alternatives)
    merged.each do |j, _|
      next if j.size <= 1
      j.each_char {|c| @decomposition_statistics[c] +=1}
    end
  end

  def fill_disambiguation_candidates(alternatives, japanese, reading, misc)
    remember_problem(alternatives)
    # if in batch mode, skip disambiguation
    return false unless @interactive

    begin
      choices = alternatives.flatten(1)
      puts "#{misc}#{japanese}(#{reading}); Choices #{choices.each_with_index.map {|ch, idx| "#{idx+1}: #{ch}" }.join('; ')}. Empty string to skip this ambiguity. Your choice?"
      idx = gets.chomp

      # skip disambiguation, b/c user doesn't want it.
      return false if idx.empty?

      if idx.start_with?('?')
        idx = idx[1..-1]
        @decomposition_cache[idx].each_pair do |_, decomp|
          puts decomp.to_s
        end
        raise "repeat"
      end

      idx = idx.to_i
      raise "Bad choice" if idx == 0

      choice = choices[idx-1]
      puts "Chose: #{choice}"
      raise "Bad choice" unless choice

      japanese, reading = choice

      put_decomposition_exclusion(japanese, reading, alternatives)
      save_decomposition_exclusions
    rescue Exception => _
      retry
    end

    true # retry disambiguation, b/c we changed exclusion table.
  end

=begin
  def fill_disambiguation_candidates(alternatives)
    alternatives.each do |decomp|
      decomp.each do |japanese, reading|
        # prevent yaml dumper from using references for those
        japanese = japanese.dup
        reading = reading.dup
        k = @disambiguation_candidates[japanese] ||= {}
        k[reading] ||= []
        k[reading] |= [alternatives]
      end
    end
  end
=end

  def decomp_sanity_check_failure?(decomp)
    prev_size = nil

    decomp.each do |j, r|
      if '々'.eql?(j)
        return true if r.size != prev_size
      end
      return true if sanity_check_failure?(j,r)
      prev_size = r.size
    end

    nil
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
    readings = @decomposition_exclusions[j]
    readings && readings.include?(r)
  end

  def sub_decompose_reading(japanese, reading)
    if japanese.size <= 0
      # if we exhausted japanese before reading - give up,
      # otherwise it's simultaneous exhaustion, return new decomposition root.
      return reading.size>0 ? nil : [Decomposition.new()]
    end
    if reading_equal?(japanese, reading)
      return [Decomposition.new(japanese.each_char.zip(reading.each_char))]
    end
    return nil if is_all_kana?(japanese) # japanese is fully kana, but reading doesn't match. failure.

    last_take = japanese.size == 1
    allowed_take = last_take ? reading.size + 1 : reading.size

    head = japanese[0]

    lg = lookup_reading(head)
    lg = lg.select do |y|
      y.size > 0 && y.size < allowed_take && reading.start_with?(y)
    end

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

    if result.empty?
      tail_decompose = sub_decompose_reading_tail(japanese, reading)
      result = tail_decompose if tail_decompose
    end

    result unless result.empty?
  end

  def sub_decompose_reading_tail(japanese, reading)
    if japanese.size <= 0
      # if we exhausted japanese before reading - give up,
      # otherwise it's simultaneous exhaustion, return new decomposition root.
      return reading.size>0 ? nil : [Decomposition.new()]
    end
    if reading_equal?(japanese, reading)
      return [Decomposition.new(japanese.each_char.zip(reading.each_char))]
    end
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

  def merge_ambiguities(alternatives)
    japanese = alternatives[0].map {|j, _| j}.join
    reading = gather_reading(alternatives[0])

    indices = Hash.new() {|_,_| 0}

    alternatives.each do |decomp|
      j_idx = 0
      r_idx = 0
      decomp.each do |j, r|
        indices[[j_idx += j.size, r_idx += r.size]] += 1
      end
    end

    indices.delete_if do |_, count|
      count < alternatives.size
    end

    indices = indices.keys.sort

    result = []

    prev_j_idx = 0
    prev_k_idx = 0
    indices.each do |j_idx, k_idx|
      result << [japanese[prev_j_idx..j_idx-1], reading[prev_k_idx..k_idx-1]]
      prev_j_idx = j_idx
      prev_k_idx = k_idx
    end

    result
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

  print "Loading decomposition exclusions..."
  ec.load_decomposition_exclusions
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
