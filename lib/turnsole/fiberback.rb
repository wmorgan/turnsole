### a Fiber backport for Ruby 1.8.
###
### an alternative is to use Threads a la https://gist.github.com/4631,
### but i like version better.

begin
  require 'fiber'
rescue LoadError

  class Fiber
    def initialize
      args, ex, @enter = callcc { |c| [nil, nil, c] }
      unless @enter
        begin
          *v = yield(*args)
          @exit.call v, nil
        rescue Exception => e
          @exit.call [], e
        end
      end
    end

    def yield(*a)
      args, ex, @enter = callcc { |c| [nil, nil, c] }
      if @enter
        @exit.call a, ex
      else
        raise ex if ex
        args.size < 2 ? args.first : args
      end
    end

    def resume(*a)
      Fiber.current = self
      args, ex, @exit = callcc { |c| [nil, nil, c] }
      if @exit
        @enter.call a, ex
      else
        raise ex if ex
        args.size < 2 ? args.first : args
      end
    end

    def alive?; @enter end

    class << self
      attr_accessor :current

      def yield(*a)
        raise "no current fiber" unless current
        current.yield(*a)
      end
    end
  end
end
