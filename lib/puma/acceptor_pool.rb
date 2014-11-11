require 'thread'

module Puma
  # A pool of sockets accepting and handling requests
  # We use SO_REUSEPORT so the Linux kernel can load
  # balance for us. This results in not needing a
  # mutex or ConditionVariable while handling requests
  class AcceptorPool

    def initialize(min, max, host, port, binder, check, *extra, &block)
      @min = Integer(min)
      @max = Integer(max)
      @block = block
      @extra = extra
      @host = host
      @port = port
      @binder = binder
      @workers = []
      @check = check
      mutex = Mutex.new

      mutex.synchronize do
        @min.times { spawn_acceptor }
      end
    end

    def spawn_acceptor
      th = Thread.new do
        todo  = @todo
        block = @block
        extra = @extra.map { |i| i.new }
        socket = create_socket
        sockets = [check] + @binder.ios

        loop do
          # Re-add trimming support later
          begin
            ios = IO.select sockets
            ios.first.each do |sock|
              if socket == check
                break if handle_check
              else
                begin
                  if io = socket.accept_nonblock
                    client = Client.new io, @binder.env(socket)
                    block.call(client, *extra)
                  end
                rescue SystemCallError
                end
              end
            end
          rescue Errno::ECONNABORTED
            # client closed the socket even before accept
            client.close rescue nil
          rescue Object => e
            @events.unknown_error self, e, "Listen loop"
          end
        end
      end

      @workers << th

      th
    end
  end

  def create_socket
    socket = Socket.new(:INET, :STREAM)
    socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
    socket.setsockopt(Socket::SOL_SOCKET, Socket::SO_REUSEPORT, 1)
    sockaddr = Socket.pack_sockaddr_in(@port, @host)
    socket.bind(sockaddr)
    socket.listen(1024)
    socket
  end
end
