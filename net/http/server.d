﻿/**
 * A simple HTTP server.
 *
 * License:
 *   This Source Code Form is subject to the terms of
 *   the Mozilla Public License, v. 2.0. If a copy of
 *   the MPL was not distributed with this file, You
 *   can obtain one at http://mozilla.org/MPL/2.0/.
 *
 * Authors:
 *   Stéphan Kochen <stephan@kochen.nl>
 *   Vladimir Panteleev <vladimir@thecybershadow.net>
 *   Simon Arlott
 */

module ae.net.http.server;

import std.string;
import std.conv;
import std.datetime;
import std.uri;
import std.exception;

import ae.net.asockets;
import ae.net.ietf.headers;
import ae.sys.data;
import ae.sys.log;
import ae.utils.text;

public import ae.net.http.common;

debug (HTTP) import std.stdio, std.datetime;

final class HttpServer
{
public:
	Logger log;

private:
	ServerSocket conn;
	TickDuration timeout;

private:
	void onClose()
	{
		if (handleClose)
			handleClose();
	}

	void onAccept(ClientSocket incoming)
	{
		debug (HTTP) writefln("[%s] New connection from %s", Clock.currTime(), incoming.remoteAddress);
		new HttpServerConnection(this, incoming);
	}

public:
	this(TickDuration timeout = TickDuration.from!"seconds"(30))
	{
		assert(timeout.length > 0);
		this.timeout = timeout;

		conn = new ServerSocket();
		conn.handleClose = &onClose;
		conn.handleAccept = &onAccept;
	}

	ushort listen(ushort port, string addr = null)
	{
		port = conn.listen(port, addr);
		if (log)
			foreach (address; conn.localAddresses)
				log("Listening on " ~ formatAddress(address) ~ " [" ~ to!string(address.addressFamily) ~ "]");
		return port;
	}

	void close()
	{
		if (log) log("Shutting down.");
		conn.close();
		conn = null;
	}

public:
	/// Callback for when the socket was closed.
	void delegate() handleClose;
	/// Callback for an incoming request.
	void delegate(HttpRequest request, HttpServerConnection conn) handleRequest;
}

final class HttpServerConnection
{
public:
	HttpServer server;
	ClientSocket conn;
	HttpRequest currentRequest;
	Address localAddress, remoteAddress;

private:
	Data inBuffer;
	int expect;  // VP 2007.01.21: changing from size_t to int because size_t is unsigned
	bool persistent;
	bool requestProcessing; // user code is asynchronously processing current request

	this(HttpServer server, ClientSocket conn)
	{
		this.server = server;
		this.conn = conn;
		conn.handleReadData = &onNewRequest;
		conn.setIdleTimeout(server.timeout);
		localAddress = conn.localAddress;
		remoteAddress = conn.remoteAddress;
		debug (HTTP) conn.handleDisconnect = &onDisconnect;
	}

	void onNewRequest(ClientSocket sender, Data data)
	{
		try
		{
			debug (HTTP) writefln("[%s] Receiving start of request: \n%s---", Clock.currTime(), cast(string)data.contents);
			inBuffer ~= data;

			auto inBufferStr = cast(string)inBuffer.contents;
			auto headersend = inBufferStr.indexOf("\r\n\r\n");
			if (headersend == -1)
				return;

			debug (HTTP) writefln("[%s] Got headers, %d bytes total", Clock.currTime(), headersend+4);
			string[] lines = splitAsciiLines(inBufferStr[0 .. headersend]);
			string reqline = lines[0];
			enforce(reqline.length > 10);
			lines = lines[1 .. lines.length];

			currentRequest = new HttpRequest();

			auto methodend = reqline.indexOf(' ');
			enforce(methodend > 0);
			currentRequest.method = reqline[0 .. methodend].idup;
			reqline = reqline[methodend + 1 .. reqline.length];

			auto resourceend = reqline.lastIndexOf(' ');
			enforce(resourceend > 0);
			currentRequest.resource = reqline[0 .. resourceend].idup;

			string protocol = reqline[resourceend+1..$];
			enforce(protocol.startsWith("HTTP/1."));
			currentRequest.protocolVersion = protocol[5..$].idup;

			foreach (string line; lines)
			{
				auto valuestart = line.indexOf(": ");
				if (valuestart > 0)
					currentRequest.headers[line[0 .. valuestart].idup] = line[valuestart + 2 .. line.length].idup;
			}

			auto connection = toLower(aaGet(currentRequest.headers, "Connection", null));
			switch (currentRequest.protocolVersion)
			{
				case "1.0":
					persistent = connection == "keep-alive";
					break;
				default: // 1.1+
					persistent = connection != "close";
					break;
			}
			debug (HTTP) writefln("[%s] This %s connection %s persistent", Clock.currTime(), currentRequest.protocolVersion, persistent ? "IS" : "is NOT");

			expect = 0;
			if ("Content-Length" in currentRequest.headers)
				expect = to!uint(currentRequest.headers["Content-Length"]);

			inBuffer.popFront(headersend+4);

			if (expect > 0)
			{
				if (expect > inBuffer.length)
					conn.handleReadData = &onContinuation;
				else
					processRequest(inBuffer.popFront(expect));
			}
			else
				processRequest(Data());
		}
		catch (Exception e)
		{
			sendResponse(null);
		}
	}

	debug (HTTP)
	void onDisconnect(ClientSocket sender, string reason, DisconnectType type)
	{
		writefln("[%s] Disconnect: %s", Clock.currTime(), reason);
	}

	void onContinuation(ClientSocket sender, Data data)
	{
		debug (HTTP) writefln("[%s] Receiving continuation of request: \n%s---", Clock.currTime(), cast(string)data.contents);
		inBuffer ~= data;

		if (!requestProcessing && inBuffer.length >= expect)
		{
			debug (HTTP) writefln("[%s] %s/%s", Clock.currTime(), inBuffer.length, expect);
			processRequest(inBuffer.popFront(expect));
		}
	}

	void processRequest(Data data)
	{
		currentRequest.data = data;
		if (server.handleRequest)
		{
			// Log unhandled exceptions, but don't mess up the stack trace
			//scope(failure) logRequest(currentRequest, null);

			// sendResponse may be called immediately, or later
			requestProcessing = true;
			server.handleRequest(currentRequest, this);
		}
	}

	void logRequest(HttpRequest request, HttpResponse response)
	{
		debug // avoid linewrap in terminal during development
			enum DEBUG = true;
		else
			enum DEBUG = false;

		if (server.log) server.log(([
			"", // align IP to tab
			request.remoteHosts(remoteAddress.toAddrString())[0],
			response ? text(response.status) : "-",
			format("%9.2f ms", request.age.usecs / 1000f),
			request.method,
			formatAddress(localAddress, aaGet(request.headers, "Host", null)) ~ request.resource,
			response ? aaGet(response.headers, "Content-Type", "-") : "-",
		] ~ (DEBUG ? [] : [
			aaGet(request.headers, "Referer", "-"),
			aaGet(request.headers, "User-Agent", "-"),
		])).join("\t"));
	}

public:
	void sendResponse(HttpResponse response)
	{
		requestProcessing = false;
		string respMessage = "HTTP/" ~ currentRequest.protocolVersion ~ " ";
		if (response)
		{
			if ("Accept-Encoding" in currentRequest.headers)
				response.compress(currentRequest.headers["Accept-Encoding"]);
			response.headers["Content-Length"] = response ? to!string(response.data.length) : "0";
			response.headers["X-Powered-By"] = "DHttp";
			if (persistent && currentRequest.protocolVersion=="1.0")
				response.headers["Connection"] = "Keep-Alive";

			respMessage ~= to!string(response.status) ~ " " ~ response.statusMessage ~ "\r\n";
			foreach (string header, string value; response.headers)
				respMessage ~= header ~ ": " ~ value ~ "\r\n";

			respMessage ~= "\r\n";
		}
		else
		{
			respMessage ~= "500 Internal Server Error\r\n\r\n";
		}

		conn.send(respMessage);
		if (response && response.data.length)
			conn.send(response.data);

		debug (HTTP) writefln("[%s] Sent response (%d bytes headers, %d bytes data)",
			Clock.currTime(), respMessage.length, response ? response.data.length : 0);

		if (persistent)
		{
			// reset for next request
			conn.handleReadData = &onNewRequest;
			if (inBuffer.length) // a second request has been pipelined
				onNewRequest(conn, Data());
		}
		else
			conn.disconnect();

		logRequest(currentRequest, response);
	}
}

string formatAddress(Address address, string vhost = null)
{
	string addr = address.toAddrString();
	string port = address.toPortString();
	return "http://" ~
		(vhost ? vhost : addr == "0.0.0.0" || addr == "::" ? "*" : addr.contains(":") ? "[" ~ addr ~ "]" : addr) ~
		(port == "80" ? "" : ":" ~ port);
}
