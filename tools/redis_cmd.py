"""One Redis command for the HTTP scenarios, without redis-cli.

    python tools/redis_cmd.py <host> <port> <command> [args...]

Prints the reply: a simple string, an integer, a bulk string ('' for nil),
or nothing when the server closes the connection (SHUTDOWN). An error reply
goes to stderr with exit code 1. Only what tools/http_scenarios_appointments.sh
needs: no arrays, no RESP3. The Linux test image has Python but no
redis-cli, and the Windows runner the same script.
"""
import socket
import sys


def main():
    host, port, args = sys.argv[1], int(sys.argv[2]), sys.argv[3:]
    request = b'*%d\r\n' % len(args)
    for arg in args:
        data = arg.encode('utf-8')
        request += b'$%d\r\n%s\r\n' % (len(data), data)
    with socket.create_connection((host, port), timeout=5) as sock:
        sock.sendall(request)
        reader = sock.makefile('rb')
        line = reader.readline()
        if not line:
            return 0  # closed without a reply: SHUTDOWN
        kind, rest = line[:1], line[1:].rstrip(b'\r\n')
        if kind in (b'+', b':'):
            print(rest.decode('utf-8'))
        elif kind == b'-':
            print(rest.decode('utf-8'), file=sys.stderr)
            return 1
        elif kind == b'$':
            size = int(rest)
            print('' if size < 0 else reader.read(size + 2)[:size].decode('utf-8'))
        else:
            print('unexpected reply: %r' % line, file=sys.stderr)
            return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
