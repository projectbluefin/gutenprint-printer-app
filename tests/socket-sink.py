#!/usr/bin/env python3
"""Accept a single TCP connection and stream its bytes to a file.

Used as the "socket sink" for a CUPS socket: backend print job. The image
under test sends its raster output to this listener; capturing the bytes lets
CI prove a real print job traversed the image without any physical printer.
"""
import socket
import sys

port = int(sys.argv[1])
output_path = sys.argv[2]

with socket.socket() as listener:
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", port))
    listener.listen(1)
    connection, _ = listener.accept()
    connection.settimeout(30)
    with connection, open(output_path, "wb") as output:
        while data := connection.recv(65536):
            output.write(data)
