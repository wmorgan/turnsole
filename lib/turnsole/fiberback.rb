### a Fiber backport for Ruby 1.8.
###
### an alternative is to use Threads a la https://gist.github.com/4631,
### but i like version better.

begin
  require 'fiber'
rescue LoadError

  class Fiber
    class << self; attr_accessor :current end

    def initialize
      @enter, args = callcc { |c| [c, nil] }
      unless @enter
        *v = yield(*args)
        @exit.call nil, v
      end
    end

    def yield(*a)
      @enter, args = callcc { |c| [c, nil] }
      if @enter
        @exit.call nil, a
      else
        args.size < 2 ? args.first : args
      end
    end

    def resume(*a)
      Fiber.current = self
      @exit, args = callcc { |c| [c, nil] }
      if @exit
        @enter.call nil, a
      else
        args.size < 2 ? args.first : args
      end
    end

    def alive?; !!@enter end

    def self.yield(*a)
      raise "no current fiber" unless Fiber.current
      Fiber.current.yield(*a)
    end
  end
end
