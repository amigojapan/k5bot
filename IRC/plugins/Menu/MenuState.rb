# encoding: utf-8
# This file is part of the K5 bot project.
# See files README.md and COPYING for copyright and licensing information.

# MenuState contains per-user state of menu_text.

class MenuState

  # The plugin, to which the menu_text hierarchy belongs.
  attr_reader :plugin

  # The size of the menu_text chunks, in number of items, to display per
  # message.
  attr_reader :menu_size

  # The duration in seconds since last access, after which the entry is
  # considered expired.
  attr_reader :expiry_duration

  # Stack array of entered nodes, in parent -> child order. Rightmost node is
  # the current one.
  attr_reader :location

  # A mark of last output item description, or null, if everything was shown.
  attr_accessor :mark

  # The children items of the current node.
  attr_accessor :items

  # Last access time
  attr_accessor :access_time

  def initialize(plugin, menu_size, expiry_duration)
    @plugin = plugin
    @menu_size = menu_size
    @expiry_duration = expiry_duration
    @access_time = Time.now.to_i
    @items = nil
    @mark = nil
    @location = []
  end

  def is_expired?()
    Time.now.to_i > @access_time + @expiry_duration
  end

  def do_access!()
    @access_time = Time.now.to_i
  end

  def get_child(index)
    return nil unless items and index > 0 and index < items.length + 1
    items[index - 1]
  end

  def move_down_to!(node, msg)
    return false unless node # get_child failed or something

    self.do_access!

    new_items = node.enter(nil, msg)
    unless new_items
      # if node is not enterable.
      on_leaf_node(node, msg) # by default, does nothing
      return false
    end
    if new_items.empty?
      # if node is enterable but empty, don't enter.
      on_empty_menu(node, msg) # by default, prints that there's nothing to look at
      return false
    end

    @location << node

    old_items = @items
    @items = new_items

    old_mark = @mark
    @mark = 0

    if new_items.length == 1
      unless self.move_down_to!(new_items[0], msg)
        # the single entry was a chain (no forks),
        # can't stay in it, rollback entering.
        if @location.size > 1
          @location.pop
          @items = old_items
          @mark = old_mark
        end
        return false
      end
      return true
    end

    #finally, a fork! print choices and remain there
    self.show_descriptions!(msg)

    true
  end

  def show_descriptions!(msg)
    self.do_access!

    if @mark
      start = @mark
      @mark += @menu_size
      has_next = @mark < @items.length
      unless has_next
        @mark = nil
      end
      has_parent = @location.size > 1
      items = @items
      size = @menu_size

      on_menu_cycle(items, start, size, has_next, has_parent, msg)
    else
      @mark = 0 # continue showing menu from the beginning

      on_menu_cycle_end(msg)
    end
  end

  def move_up!(msg)
    self.do_access!

    # don't allow to pop higher than topmost node
    unless @location.size > 1
      on_root_exit(msg)
      return false
    end

    child = @location.pop
    parent = @location[-1]

    # in case, if node is somehow no longer enterable
    @items = parent.enter(child, msg) || []

    @mark = 0

    self.show_descriptions!(msg)

    true
  end

  def render_menu_header(menu_items, start)
    start == 0 ? "#{menu_items.length} hits: " : ''
  end

  def render_menu_items(menu_items, start, size)
    menu_items[start, size].map.with_index do |e, i|
      "#{i + start + 1} #{e.description}"
    end.join(' | ')
  end

  def render_menu_footer(has_next, has_parent)
    footer = ''

    if has_next
      footer += " [#{IRCMessage::BotCommandPrefix}n for next]"
    end

    if has_parent
      footer += " [#{IRCMessage::BotCommandPrefix}u to go up]"
    end

    footer
  end

  # Overridable behavior for when current menu contents is asked to be shown
  def on_menu_cycle(items, start, size, has_next, has_parent, msg)
    menu_text = render_menu_header(items, start)
    menu_text += render_menu_items(items, start, size)
    menu_text += render_menu_footer(has_next, has_parent)

    msg.reply(menu_text)
  end

  # Overridable behavior for when current menu content is exhausted
  def on_menu_cycle_end(msg)
    msg.reply("No more hits.")
  end

  # Overridable behavior for when given node was attempted to be entered into,
  # yet it is a leaf node.
  #noinspection RubyUnusedLocalVariable
  def on_leaf_node(node, msg)
  end

  # Overridable behavior for when given node was attempted to be entered into,
  # yet it yielded empty children list.
  def on_empty_menu(node, msg)
    msg.reply(node.description ? "No hits for #{node.description}." : "No hits.")
  end

  # Overridable behavior for when user attempted to move higher than root node.
  def on_root_exit(msg)
    msg.reply("Can't move further up.")
  end
end
