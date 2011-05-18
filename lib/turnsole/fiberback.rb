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

f1 = Fiber.new do |x|
  puts "f1 in start with #{x.inspect}"
  x = Fiber.yield 3
  puts "f1 in, got #{x.inspect}"
  x = Fiber.yield 4, 5
  puts "f1 in, got #{x.inspect}"
  puts "f1 in done"
end

f2 = Fiber.new do |x|
  puts "f2 in start with #{x.inspect}"
  x = Fiber.yield
  puts "f2 in, got #{x.inspect}"
  x = Fiber.yield [99]
  puts "f2 in, got #{x.inspect}"
  puts "f2 in done"
  234
end

__END__

puts "out start"
x = f1.resume 1
puts "out, from f1 got #{x.inspect}"

y = f2.resume "a"
puts "out, from f2 got #{y.inspect}"

x = f1.resume
puts "out, from f1 got #{x.inspect}"

y = f2.resume ["b", "y"]
puts "out, from f2 got #{y.inspect}"

x = f1.resume 9
puts "out done with f1, got #{x.inspect}"

y = f2.resume "c"
puts "out done with f2, got #{y.inspect}"

