module eventcore.drivers.posix.sockets;
@safe:

import eventcore.driver;
import eventcore.drivers.posix.driver;
import eventcore.internal.utils;

import std.algorithm.comparison : among, min, max;
import std.socket : Address, AddressFamily, InternetAddress, Internet6Address, UnknownAddress;

version (Posix) {
	import std.socket : UnixAddress;
	import core.sys.posix.netdb : AI_ADDRCONFIG, AI_V4MAPPED, addrinfo, freeaddrinfo, getaddrinfo;
	import core.sys.posix.netinet.in_;
	import core.sys.posix.netinet.tcp;
	import core.sys.posix.sys.un;
	import core.sys.posix.unistd : close, read, write;
	import core.stdc.errno : errno, EAGAIN, EINPROGRESS;
	import core.sys.posix.fcntl;

	version (linux) enum SO_REUSEPORT = 15;
	else enum SO_REUSEPORT = 0x200;
}
version (Windows) {
	import core.sys.windows.windows;
	import core.sys.windows.winsock2;
	alias sockaddr_storage = SOCKADDR_STORAGE;
	alias EAGAIN = WSAEWOULDBLOCK;
	enum SHUT_RDWR = SD_BOTH;
	enum SHUT_RD = SD_RECEIVE;
	enum SHUT_WR = SD_SEND;
	extern (C) int read(int fd, void *buffer, uint count) nothrow;
	extern (C) int write(int fd, const(void) *buffer, uint count) nothrow;
	extern (C) int close(int fd) nothrow @safe;
}


final class PosixEventDriverSockets(Loop : PosixEventLoop) : EventDriverSockets {
@safe: /*@nogc:*/ nothrow:
	private Loop m_loop;

	this(Loop loop) { m_loop = loop; }

	final override StreamSocketFD connectStream(scope Address address, scope Address bind_address, ConnectCallback on_connect)
	{
		assert(on_connect !is null);

		auto sockfd = createSocket(address.addressFamily, SOCK_STREAM);
		if (sockfd == -1) return StreamSocketFD.invalid;

		auto sock = cast(StreamSocketFD)sockfd;

		void invalidateSocket() @nogc @trusted nothrow { closeSocket(sockfd); sock = StreamSocketFD.invalid; }

		int bret;
		if (bind_address !is null)
			() @trusted { bret = bind(cast(sock_t)sock, bind_address.name, bind_address.nameLen); } ();

		if (bret != 0) {
			invalidateSocket();
			on_connect(sock, ConnectStatus.bindFailure);
			return sock;
		}

		m_loop.initFD(sock);
		m_loop.registerFD(sock, EventMask.read|EventMask.write|EventMask.status);
		m_loop.m_fds[sock].specific = StreamSocketSlot.init;
		m_loop.setNotifyCallback!(EventType.status)(sock, &onConnectError);
		releaseRef(sock); // setNotifyCallback adds a reference, but waiting for status/disconnect should not affect the ref count

		auto ret = () @trusted { return connect(cast(sock_t)sock, address.name, address.nameLen); } ();
		if (ret == 0) {
			m_loop.m_fds[sock].specific.state = ConnectionState.connected;
			on_connect(sock, ConnectStatus.connected);
		} else {
			auto err = getSocketError();
			if (err.among!(EAGAIN, EINPROGRESS)) {
				with (m_loop.m_fds[sock].streamSocket) {
					connectCallback = on_connect;
					state = ConnectionState.connecting;
				}
				m_loop.setNotifyCallback!(EventType.write)(sock, &onConnect);
			} else {
				m_loop.clearFD(sock);
				m_loop.unregisterFD(sock, EventMask.read|EventMask.write|EventMask.status);
				invalidateSocket();
				on_connect(sock, ConnectStatus.unknownError);
				return sock;
			}
		}

		return sock;
	}

	final override StreamSocketFD adoptStream(int socket)
	{
		auto fd = StreamSocketFD(socket);
		if (m_loop.m_fds[fd].common.refCount) // FD already in use?
			return StreamSocketFD.invalid;
		setSocketNonBlocking(fd);
		m_loop.initFD(fd);
		m_loop.registerFD(fd, EventMask.read|EventMask.write|EventMask.status);
		m_loop.m_fds[fd].specific = StreamSocketSlot.init;
		return fd;
	}

	private void onConnect(FD sock)
	{
		m_loop.setNotifyCallback!(EventType.write)(sock, null);
		with (m_loop.m_fds[sock].streamSocket) {
			state = ConnectionState.connected;
			auto cb = connectCallback;
			connectCallback = null;
			if (cb) cb(cast(StreamSocketFD)sock, ConnectStatus.connected);
		}
	}

	private void onConnectError(FD sock)
	{
		// FIXME: determine the correct kind of error!
		with (m_loop.m_fds[sock].streamSocket) {
			state = ConnectionState.closed;
			auto cb = connectCallback;
			connectCallback = null;
			if (cb) cb(cast(StreamSocketFD)sock, ConnectStatus.refused);
		}
	}

	alias listenStream = EventDriverSockets.listenStream;
	final override StreamListenSocketFD listenStream(scope Address address, StreamListenOptions options, AcceptCallback on_accept)
	{
		log("Listen stream");
		auto sockfd = createSocket(address.addressFamily, SOCK_STREAM);
		if (sockfd == -1) return StreamListenSocketFD.invalid;

		auto sock = cast(StreamListenSocketFD)sockfd;

		void invalidateSocket() @nogc @trusted nothrow { closeSocket(sockfd); sock = StreamSocketFD.invalid; }

		() @trusted {
			int tmp_reuse = 1;
			// FIXME: error handling!
			if (setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &tmp_reuse, tmp_reuse.sizeof) != 0) {
				log("setsockopt SO_REUSEADDR failed.");
				invalidateSocket();
				return;
			}
			version (Windows) {} else {
				if ((options & StreamListenOptions.reusePort) && setsockopt(sockfd, SOL_SOCKET, SO_REUSEPORT, &tmp_reuse, tmp_reuse.sizeof) != 0) {
					log("setsockopt SO_REUSEPORT failed.");
					invalidateSocket();
					return;
				}
			}
			if (bind(sockfd, address.name, address.nameLen) != 0) {
				log("bind failed.");
				invalidateSocket();
				return;
			}
			if (listen(sockfd, 128) != 0) {
				log("listen failed.");
				invalidateSocket();
				return;
			}
			log("Success!");
		} ();

		if (sock == StreamListenSocketFD.invalid)
			return sock;

		m_loop.initFD(sock);
		m_loop.m_fds[sock].specific = StreamListenSocketSlot.init;

		if (on_accept) waitForConnections(sock, on_accept);

		return sock;
	}

	final override void waitForConnections(StreamListenSocketFD sock, AcceptCallback on_accept)
	{
		log("wait for conn");
		m_loop.registerFD(sock, EventMask.read);
		m_loop.m_fds[sock].streamListen.acceptCallback = on_accept;
		m_loop.setNotifyCallback!(EventType.read)(sock, &onAccept);
		onAccept(sock);
	}

	private void onAccept(FD listenfd)
	{
		foreach (i; 0 .. 20) {
			sock_t sockfd;
			sockaddr_storage addr;
			socklen_t addr_len = addr.sizeof;
			() @trusted { sockfd = accept(cast(sock_t)listenfd, () @trusted { return cast(sockaddr*)&addr; } (), &addr_len); } ();
			if (sockfd == -1) break;

			setSocketNonBlocking(cast(SocketFD)sockfd);
			auto fd = cast(StreamSocketFD)sockfd;
			m_loop.initFD(fd);
			m_loop.m_fds[fd].specific = StreamSocketSlot.init;
			m_loop.m_fds[fd].streamSocket.state = ConnectionState.connected;
			m_loop.registerFD(fd, EventMask.read|EventMask.write|EventMask.status);
			m_loop.setNotifyCallback!(EventType.status)(fd, &onConnectError);
			releaseRef(fd); // setNotifyCallback adds a reference, but waiting for status/disconnect should not affect the ref count
			//print("accept %d", sockfd);
			scope RefAddress addrc = new RefAddress(() @trusted { return cast(sockaddr*)&addr; } (), addr_len);
			m_loop.m_fds[listenfd].streamListen.acceptCallback(cast(StreamListenSocketFD)listenfd, fd, addrc);
		}
	}

	ConnectionState getConnectionState(StreamSocketFD sock)
	{
		return m_loop.m_fds[sock].streamSocket.state;
	}

	bool getLocalAddress(StreamSocketFD sock, scope RefAddress dst)
	{
		socklen_t addr_len = dst.nameLen;
		if (() @trusted { return getsockname(cast(sock_t)sock, dst.name, &addr_len); } () != 0)
			return false;
		dst.cap(addr_len);
		return true;
	}


	final override void setTCPNoDelay(StreamSocketFD socket, bool enable)
	{
		int opt = enable;
		() @trusted { setsockopt(cast(sock_t)socket, IPPROTO_TCP, TCP_NODELAY, cast(char*)&opt, opt.sizeof); } ();
	}

	final override void setKeepAlive(StreamSocketFD socket, bool enable)
	{
		ubyte opt = enable;
		() @trusted { setsockopt(cast(sock_t)socket, SOL_SOCKET, SO_KEEPALIVE, cast(char*)&opt, opt.sizeof); } ();
	}

	final override void read(StreamSocketFD socket, ubyte[] buffer, IOMode mode, IOCallback on_read_finish)
	{
		/*if (buffer.length == 0) {
			on_read_finish(socket, IOStatus.ok, 0);
			return;
		}*/

		sizediff_t ret;
		() @trusted { ret = .recv(cast(sock_t)socket, buffer.ptr, min(buffer.length, int.max), 0); } ();

		if (ret < 0) {
			auto err = getSocketError();
			if (!err.among!(EAGAIN, EINPROGRESS)) {
				print("sock error %s!", err);
				on_read_finish(socket, IOStatus.error, 0);
				return;
			}
		}

		if (ret == 0 && buffer.length > 0) {
			on_read_finish(socket, IOStatus.disconnected, 0);
			return;
		}

		if (ret < 0 && mode == IOMode.immediate) {
			on_read_finish(socket, IOStatus.wouldBlock, 0);
			return;
		}

		if (ret >= 0) {
			buffer = buffer[ret .. $];
			if (mode != IOMode.all || buffer.length == 0) {
				on_read_finish(socket, IOStatus.ok, ret);
				return;
			}
		}

		// NOTE: since we know that not all data was read from the stream
		//       socket, the next call to recv is guaranteed to return EGAIN
		//       and we can avoid that call.

		with (m_loop.m_fds[socket].streamSocket) {
			readCallback = on_read_finish;
			readMode = mode;
			bytesRead = ret > 0 ? ret : 0;
			readBuffer = buffer;
		}

		m_loop.setNotifyCallback!(EventType.read)(socket, &onSocketRead);
	}

	override void cancelRead(StreamSocketFD socket)
	{
		assert(m_loop.m_fds[socket].streamSocket.readCallback !is null, "Cancelling read when there is no read in progress.");
		m_loop.setNotifyCallback!(EventType.read)(socket, null);
		with (m_loop.m_fds[socket].streamSocket) {
			readBuffer = null;
		}
	}

	private void onSocketRead(FD fd)
	{
		auto slot = () @trusted { return &m_loop.m_fds[fd].streamSocket(); } ();
		auto socket = cast(StreamSocketFD)fd;

		void finalize()(IOStatus status)
		{
			m_loop.setNotifyCallback!(EventType.read)(socket, null);
			//m_fds[fd].readBuffer = null;
			slot.readCallback(socket, status, slot.bytesRead);
		}

		sizediff_t ret = 0;
		() @trusted { ret = .recv(cast(sock_t)socket, slot.readBuffer.ptr, min(slot.readBuffer.length, int.max), 0); } ();
		if (ret < 0) {
			auto err = getSocketError();
			if (!err.among!(EAGAIN, EINPROGRESS)) {
				finalize(IOStatus.error);
				return;
			}
		}

		if (ret == 0 && slot.readBuffer.length) {
			slot.state = ConnectionState.passiveClose;
			finalize(IOStatus.disconnected);
			return;
		}

		if (ret > 0 || !slot.readBuffer.length) {
			slot.bytesRead += ret;
			slot.readBuffer = slot.readBuffer[ret .. $];
			if (slot.readMode != IOMode.all || slot.readBuffer.length == 0) {
				finalize(IOStatus.ok);
				return;
			}
		}
	}

	final override void write(StreamSocketFD socket, const(ubyte)[] buffer, IOMode mode, IOCallback on_write_finish)
	{
		if (buffer.length == 0) {
			on_write_finish(socket, IOStatus.ok, 0);
			return;
		}

		sizediff_t ret;
		() @trusted { ret = .send(cast(sock_t)socket, buffer.ptr, min(buffer.length, int.max), 0); } ();

		if (ret < 0) {
			auto err = getSocketError();
			if (!err.among!(EAGAIN, EINPROGRESS)) {
				on_write_finish(socket, IOStatus.error, 0);
				return;
			}
		}

		size_t bytes_written = 0;

		if (ret == 0) {
			on_write_finish(socket, IOStatus.disconnected, 0);
			return;
		}

		if (ret < 0 && mode == IOMode.immediate) {
			on_write_finish(socket, IOStatus.wouldBlock, 0);
			return;
		}

		if (ret > 0) {
			bytes_written += ret;
			buffer = buffer[ret .. $];
			if (mode != IOMode.all || buffer.length == 0) {
				on_write_finish(socket, IOStatus.ok, bytes_written);
				return;
			}
		}

		// NOTE: since we know that not all data was writtem to the stream
		//       socket, the next call to send is guaranteed to return EGAIN
		//       and we can avoid that call.

		with (m_loop.m_fds[socket].streamSocket) {
			writeCallback = on_write_finish;
			writeMode = mode;
			bytesWritten = ret > 0 ? ret : 0;
			writeBuffer = buffer;
		}

		m_loop.setNotifyCallback!(EventType.write)(socket, &onSocketWrite);
	}

	override void cancelWrite(StreamSocketFD socket)
	{
		assert(m_loop.m_fds[socket].streamSocket.writeCallback !is null, "Cancelling write when there is no write in progress.");
		m_loop.setNotifyCallback!(EventType.write)(socket, null);
		m_loop.m_fds[socket].streamSocket.writeBuffer = null;
	}

	private void onSocketWrite(FD fd)
	{
		auto slot = () @trusted { return &m_loop.m_fds[fd].streamSocket(); } ();
		auto socket = cast(StreamSocketFD)fd;

		sizediff_t ret;
		() @trusted { ret = .send(cast(sock_t)socket, slot.writeBuffer.ptr, min(slot.writeBuffer.length, int.max), 0); } ();

		if (ret < 0) {
			auto err = getSocketError();
			if (!err.among!(EAGAIN, EINPROGRESS)) {
				m_loop.setNotifyCallback!(EventType.write)(socket, null);
				slot.writeCallback(socket, IOStatus.error, slot.bytesRead);
				return;
			}
		}

		if (ret == 0) {
			m_loop.setNotifyCallback!(EventType.write)(socket, null);
			slot.writeCallback(cast(StreamSocketFD)socket, IOStatus.disconnected, slot.bytesWritten);
			return;
		}

		if (ret > 0) {
			slot.bytesWritten += ret;
			slot.writeBuffer = slot.writeBuffer[ret .. $];
			if (slot.writeMode != IOMode.all || slot.writeBuffer.length == 0) {
				m_loop.setNotifyCallback!(EventType.write)(socket, null);
				slot.writeCallback(cast(StreamSocketFD)socket, IOStatus.ok, slot.bytesWritten);
				return;
			}
		}
	}

	final override void waitForData(StreamSocketFD socket, IOCallback on_data_available)
	{
		sizediff_t ret;
		ubyte dummy;
		() @trusted { ret = recv(cast(sock_t)socket, &dummy, 1, MSG_PEEK); } ();

		if (ret < 0) {
			auto err = getSocketError();
			if (!err.among!(EAGAIN, EINPROGRESS)) {
				on_data_available(socket, IOStatus.error, 0);
				return;
			}
		}

		size_t bytes_read = 0;

		if (ret == 0) {
			on_data_available(socket, IOStatus.disconnected, 0);
			return;
		}

		if (ret > 0) {
			on_data_available(socket, IOStatus.ok, 0);
			return;
		}

		with (m_loop.m_fds[socket].streamSocket) {
			readCallback = on_data_available;
			readMode = IOMode.once;
			bytesRead = 0;
			readBuffer = null;
		}

		m_loop.setNotifyCallback!(EventType.read)(socket, &onSocketDataAvailable);
	}

	private void onSocketDataAvailable(FD fd)
	{
		auto slot = () @trusted { return &m_loop.m_fds[fd].streamSocket(); } ();
		auto socket = cast(StreamSocketFD)fd;

		void finalize()(IOStatus status)
		{
			m_loop.setNotifyCallback!(EventType.read)(socket, null);
			//m_fds[fd].readBuffer = null;
			slot.readCallback(socket, status, 0);
		}

		sizediff_t ret;
		ubyte tmp;
		() @trusted { ret = recv(cast(sock_t)socket, &tmp, 1, MSG_PEEK); } ();
		if (ret < 0) {
			auto err = getSocketError();
			if (!err.among!(EAGAIN, EINPROGRESS)) finalize(IOStatus.error);
		} else finalize(ret ? IOStatus.ok : IOStatus.disconnected);
	}

	final override void shutdown(StreamSocketFD socket, bool shut_read, bool shut_write)
	{
		auto st = m_loop.m_fds[socket].streamSocket.state;
		() @trusted { .shutdown(cast(sock_t)socket, shut_read ? shut_write ? SHUT_RDWR : SHUT_RD : shut_write ? SHUT_WR : 0); } ();
		if (st == ConnectionState.passiveClose) shut_read = true;
		if (st == ConnectionState.activeClose) shut_write = true;
		m_loop.m_fds[socket].streamSocket.state = shut_read ? shut_write ? ConnectionState.closed : ConnectionState.passiveClose : shut_write ? ConnectionState.activeClose : ConnectionState.connected;
	}

	final override DatagramSocketFD createDatagramSocket(scope Address bind_address, scope Address target_address)
	{
		auto sockfd = createSocket(bind_address.addressFamily, SOCK_DGRAM);
		if (sockfd == -1) return DatagramSocketFD.invalid;
		auto sock = cast(DatagramSocketFD)sockfd;

		if (bind_address && () @trusted { return bind(sockfd, bind_address.name, bind_address.nameLen); } () != 0) {
			closeSocket(sockfd);
			return DatagramSocketFD.init;
		}

		if (target_address) {
			int ret;
			if (target_address is bind_address) {
				// special case of bind_address==target_address: determine the actual bind address
				// in case of a zero port
				sockaddr_storage sa;
				socklen_t addr_len = sa.sizeof;
				if (() @trusted { return getsockname(sockfd, cast(sockaddr*)&sa, &addr_len); } () != 0) {
					closeSocket(sockfd);
					return DatagramSocketFD.init;
				}

				ret = () @trusted { return connect(sockfd, cast(sockaddr*)&sa, addr_len); } ();
			} else ret = () @trusted { return connect(sockfd, target_address.name, target_address.nameLen); } ();
			
			if (ret != 0) {
				closeSocket(sockfd);
				return DatagramSocketFD.init;
			}
		}

		m_loop.initFD(sock);
		m_loop.m_fds[sock].specific = DgramSocketSlot.init;
		m_loop.registerFD(sock, EventMask.read|EventMask.write|EventMask.status);

		return sock;
	}

	final override DatagramSocketFD adoptDatagramSocket(int socket)
	{
		auto fd = DatagramSocketFD(socket);
		if (m_loop.m_fds[fd].common.refCount) // FD already in use?
			return DatagramSocketFD.init;
		setSocketNonBlocking(fd);
		m_loop.initFD(fd);
		m_loop.registerFD(fd, EventMask.read|EventMask.write|EventMask.status);
		m_loop.m_fds[fd].specific = DgramSocketSlot.init;
		return fd;
	}

	final override bool setBroadcast(DatagramSocketFD socket, bool enable)
	{
		int tmp_broad = enable;
		return () @trusted { return setsockopt(cast(sock_t)socket, SOL_SOCKET, SO_BROADCAST, &tmp_broad, tmp_broad.sizeof); } () == 0;
	}

	void receive(DatagramSocketFD socket, ubyte[] buffer, IOMode mode, DatagramIOCallback on_receive_finish)
	@trusted { // DMD 2.072.0-b2: scope considered unsafe
		import std.typecons : scoped;

		assert(mode != IOMode.all, "Only IOMode.immediate and IOMode.once allowed for datagram sockets.");

		sizediff_t ret;
		sockaddr_storage src_addr;
		socklen_t src_addr_len = src_addr.sizeof;
		() @trusted { ret = .recvfrom(cast(sock_t)socket, buffer.ptr, min(buffer.length, int.max), 0, cast(sockaddr*)&src_addr, &src_addr_len); } ();

		if (ret < 0) {
			auto err = getSocketError();
			if (!err.among!(EAGAIN, EINPROGRESS)) {
				print("sock error %s for %s!", err, socket);
				on_receive_finish(socket, IOStatus.error, 0, null);
				return;
			}

			if (mode == IOMode.immediate) {
				on_receive_finish(socket, IOStatus.wouldBlock, 0, null);
			} else {
				with (m_loop.m_fds[socket].datagramSocket) {
					readCallback = on_receive_finish;
					readMode = mode;
					bytesRead = 0;
					readBuffer = buffer;
				}

				m_loop.setNotifyCallback!(EventType.read)(socket, &onDgramRead);
			}
			return;
		}

		scope src_addrc = new RefAddress(() @trusted { return cast(sockaddr*)&src_addr; } (), src_addr_len);
		on_receive_finish(socket, IOStatus.ok, ret, src_addrc);
	}

	void cancelReceive(DatagramSocketFD socket)
	{
		assert(m_loop.m_fds[socket].datagramSocket.readCallback !is null, "Cancelling read when there is no read in progress.");
		m_loop.setNotifyCallback!(EventType.read)(socket, null);
		m_loop.m_fds[socket].datagramSocket.readBuffer = null;
	}

	private void onDgramRead(FD fd)
	@trusted { // DMD 2.072.0-b2: scope considered unsafe
		auto slot = () @trusted { return &m_loop.m_fds[fd].datagramSocket(); } ();
		auto socket = cast(DatagramSocketFD)fd;

		sizediff_t ret;
		sockaddr_storage src_addr;
		socklen_t src_addr_len = src_addr.sizeof;
		() @trusted { ret = .recvfrom(cast(sock_t)socket, slot.readBuffer.ptr, min(slot.readBuffer.length, int.max), 0, cast(sockaddr*)&src_addr, &src_addr_len); } ();

		if (ret < 0) {
			auto err = getSocketError();
			if (!err.among!(EAGAIN, EINPROGRESS)) {
				m_loop.setNotifyCallback!(EventType.read)(socket, null);
				slot.readCallback(socket, IOStatus.error, 0, null);
				return;
			}
		}

		m_loop.setNotifyCallback!(EventType.read)(socket, null);
		scope src_addrc = new RefAddress(() @trusted { return cast(sockaddr*)&src_addr; } (), src_addr.sizeof);
		() @trusted { return cast(DatagramIOCallback)slot.readCallback; } ()(socket, IOStatus.ok, ret, src_addrc);
	}

	void send(DatagramSocketFD socket, const(ubyte)[] buffer, IOMode mode, Address target_address, DatagramIOCallback on_send_finish)
	{
		assert(mode != IOMode.all, "Only IOMode.immediate and IOMode.once allowed for datagram sockets.");

		sizediff_t ret;
		if (target_address) {
			() @trusted { ret = .sendto(cast(sock_t)socket, buffer.ptr, min(buffer.length, int.max), 0, target_address.name, target_address.nameLen); } ();
			m_loop.m_fds[socket].datagramSocket.targetAddr = target_address;
		} else {
			() @trusted { ret = .send(cast(sock_t)socket, buffer.ptr, min(buffer.length, int.max), 0); } ();
		}

		if (ret < 0) {
			auto err = getSocketError();
			if (!err.among!(EAGAIN, EINPROGRESS)) {
				print("sock error %s!", err);
				on_send_finish(socket, IOStatus.error, 0, null);
				return;
			}

			if (mode == IOMode.immediate) {
				on_send_finish(socket, IOStatus.wouldBlock, 0, null);
			} else {
				with (m_loop.m_fds[socket].datagramSocket) {
					writeCallback = on_send_finish;
					writeMode = mode;
					bytesWritten = 0;
					writeBuffer = buffer;
				}

				m_loop.setNotifyCallback!(EventType.write)(socket, &onDgramWrite);
			}
			return;
		}

		on_send_finish(socket, IOStatus.ok, ret, null);
	}

	void cancelSend(DatagramSocketFD socket)
	{
		assert(m_loop.m_fds[socket].datagramSocket.writeCallback !is null, "Cancelling write when there is no write in progress.");
		m_loop.setNotifyCallback!(EventType.write)(socket, null);
		m_loop.m_fds[socket].datagramSocket.writeBuffer = null;
	}

	private void onDgramWrite(FD fd)
	{
		auto slot = () @trusted { return &m_loop.m_fds[fd].datagramSocket(); } ();
		auto socket = cast(DatagramSocketFD)fd;

		sizediff_t ret;
		if (slot.targetAddr) {
			() @trusted { ret = .sendto(cast(sock_t)socket, slot.writeBuffer.ptr, min(slot.writeBuffer.length, int.max), 0, slot.targetAddr.name, slot.targetAddr.nameLen); } ();
		} else {
			() @trusted { ret = .send(cast(sock_t)socket, slot.writeBuffer.ptr, min(slot.writeBuffer.length, int.max), 0); } ();
		}

		if (ret < 0) {
			auto err = getSocketError();
			if (!err.among!(EAGAIN, EINPROGRESS)) {
				m_loop.setNotifyCallback!(EventType.write)(socket, null);
				() @trusted { return cast(DatagramIOCallback)slot.writeCallback; } ()(socket, IOStatus.error, 0, null);
				return;
			}
		}

		m_loop.setNotifyCallback!(EventType.write)(socket, null);
		() @trusted { return cast(DatagramIOCallback)slot.writeCallback; } ()(socket, IOStatus.ok, ret, null);
	}

	final override void addRef(SocketFD fd)
	{
		assert(m_loop.m_fds[fd].common.refCount > 0, "Adding reference to unreferenced socket FD.");
		m_loop.m_fds[fd].common.refCount++;
	}

	final override bool releaseRef(SocketFD fd)
	{
		assert(m_loop.m_fds[fd].common.refCount > 0, "Releasing reference to unreferenced socket FD.");
		print("release %s %s", fd, m_loop.m_fds[fd].common.refCount);
		if (--m_loop.m_fds[fd].common.refCount == 0) {
			m_loop.unregisterFD(fd, EventMask.read|EventMask.write|EventMask.status);
			m_loop.clearFD(fd);
			closeSocket(cast(sock_t)fd);
			return false;
		}
		return true;
	}

	private sock_t createSocket(AddressFamily family, int type)
	{
		sock_t sock;
		() @trusted { sock = socket(family, type, 0); } ();
		if (sock == -1) return -1;
		setSocketNonBlocking(cast(SocketFD)sock);
		return sock;
	}
}

package struct StreamSocketSlot {
	alias Handle = StreamSocketFD;

	size_t bytesRead;
	ubyte[] readBuffer;
	IOMode readMode;
	IOCallback readCallback; // FIXME: this type only works for stream sockets

	size_t bytesWritten;
	const(ubyte)[] writeBuffer;
	IOMode writeMode;
	IOCallback writeCallback; // FIXME: this type only works for stream sockets

	ConnectCallback connectCallback;
	ConnectionState state;
}

package struct StreamListenSocketSlot {
	alias Handle = StreamListenSocketFD;

	AcceptCallback acceptCallback;
}

package struct DgramSocketSlot {
	alias Handle = DatagramSocketFD;
	size_t bytesRead;
	ubyte[] readBuffer;
	IOMode readMode;
	DatagramIOCallback readCallback; // FIXME: this type only works for stream sockets

	size_t bytesWritten;
	const(ubyte)[] writeBuffer;
	IOMode writeMode;
	DatagramIOCallback writeCallback; // FIXME: this type only works for stream sockets
	Address targetAddr;
}

private void closeSocket(sock_t sockfd)
@nogc nothrow {
	version (Windows) () @trusted { closesocket(sockfd); } ();
	else close(sockfd);
}

private void setSocketNonBlocking(SocketFD sockfd)
@nogc nothrow {
	version (Windows) {
		uint enable = 1;
		() @trusted { ioctlsocket(sockfd, FIONBIO, &enable); } ();
	} else {
		() @trusted { fcntl(cast(int)sockfd, F_SETFL, O_NONBLOCK, 1); } ();
	}
}

private int getSocketError()
@nogc nothrow {
	version (Windows) return WSAGetLastError();
	else return errno;
}
