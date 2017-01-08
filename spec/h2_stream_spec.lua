describe("http.h2_stream", function()
	local h2_connection = require "http.h2_connection"
	local h2_error = require "http.h2_error"
	local new_headers = require "http.headers".new
	local cqueues = require "cqueues"
	local ca = require "cqueues.auxlib"
	local cs = require "cqueues.socket"
	local function new_pair()
		local s, c = ca.assert(cs.pair())
		s = assert(h2_connection.new(s, "server"))
		c = assert(h2_connection.new(c, "client"))
		return s, c
	end
	it("breaks up a large header block into continuation frames", function()
		local s, c = new_pair()
		local cq = cqueues.new()
		local req_headers = new_headers()
		req_headers:append(":method", "GET")
		req_headers:append(":scheme", "http")
		req_headers:append(":path", "/")
		req_headers:append("unknown", ("a"):rep(16384*3)) -- at least 3 frames worth
		cq:wrap(function()
			local client_stream = c:new_stream()
			assert(client_stream:write_headers(req_headers, true))
			assert(c:close())
		end)
		cq:wrap(function()
			local stream = assert(s:get_next_incoming_stream())
			local response_headers = assert(stream:get_headers())
			assert.same(req_headers, response_headers)
			assert(s:close())
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
	it("can send a body", function()
		local s, c = new_pair()
		local cq = cqueues.new()
		cq:wrap(function()
			local client_stream = c:new_stream()
			local req_headers = new_headers()
			req_headers:append(":method", "GET")
			req_headers:append(":scheme", "http")
			req_headers:append(":path", "/")
			-- use non-integer timeouts to catch errors with integer vs number
			assert(client_stream:write_headers(req_headers, false, 1.1))
			assert(client_stream:write_chunk("some body", false, 1.1))
			assert(client_stream:write_chunk("more body", true, 1.1))
			assert(c:close())
		end)
		cq:wrap(function()
			local stream = assert(s:get_next_incoming_stream())
			local body = assert(stream:get_body_as_string(1.1))
			assert.same("some bodymore body", body)
			assert(s:close())
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
	end)
	it("errors if content-length is exceeded", function()
		local s, c = new_pair()
		local cq = cqueues.new()
		cq:wrap(function()
			local client_stream = c:new_stream()
			local req_headers = new_headers()
			req_headers:append(":method", "GET")
			req_headers:append(":scheme", "http")
			req_headers:append(":path", "/")
			req_headers:append("content-length", "2")
			assert(client_stream:write_headers(req_headers, false))
			assert(client_stream:write_chunk("body longer than 2 bytes", true))
		end)
		cq:wrap(function()
			local stream = assert(s:get_next_incoming_stream())
			local ok, err = stream:get_body_as_string()
			assert.falsy(ok)
			assert.truthy(h2_error.is(err))
			assert.same(h2_error.errors.PROTOCOL_ERROR.code, err.code)
			assert.same("content-length exceeded", err.message)
			assert(s:close())
		end)
		assert_loop(cq, TEST_TIMEOUT)
		assert.truthy(cq:empty())
		c:close()
	end)
	describe("correct state transitions", function()
		it("closes a stream when writing headers to a half-closed stream", function()
			local s, c = new_pair()
			local cq = cqueues.new()
			cq:wrap(function()
				local client_stream = c:new_stream()
				local req_headers = new_headers()
				req_headers:append(":method", "GET")
				req_headers:append(":scheme", "http")
				req_headers:append(":path", "/")
				req_headers:append(":authority", "example.com")
				assert(client_stream:write_headers(req_headers, false))
				assert(client_stream:get_headers())
				assert(c:close())
			end)
			cq:wrap(function()
				local stream = assert(s:get_next_incoming_stream())
				assert(stream:get_headers())
				local res_headers = new_headers()
				res_headers:append(":status", "200")
				assert(stream:write_headers(res_headers, true))
				assert("closed", stream.state)
				assert(s:close())
			end)
			assert_loop(cq, TEST_TIMEOUT)
			assert.truthy(cq:empty())
		end)
	end)
	describe("push_promise", function()
		it("permits a simple push promise from server => client", function()
			local s, c = new_pair()
			local cq = cqueues.new()
			cq:wrap(function()
				local client_stream = c:new_stream()
				local req_headers = new_headers()
				req_headers:append(":method", "GET")
				req_headers:append(":scheme", "http")
				req_headers:append(":path", "/")
				req_headers:append(":authority", "example.com")
				assert(client_stream:write_headers(req_headers, true))
				local pushed_stream = assert(c:get_next_incoming_stream())
				do
					local h = assert(pushed_stream:get_headers())
					assert.same("GET", h:get(":method"))
					assert.same("http", h:get(":scheme"))
					assert.same("/foo", h:get(":path"))
					assert.same(req_headers:get(":authority"), h:get(":authority"))
					assert.same(nil, pushed_stream:get_next_chunk())
				end
				assert(c:close())
			end)
			cq:wrap(function()
				local stream = assert(s:get_next_incoming_stream())
				do
					local h = assert(stream:get_headers())
					assert.same("GET", h:get(":method"))
					assert.same("http", h:get(":scheme"))
					assert.same("/", h:get(":path"))
					assert.same("example.com", h:get(":authority"))
					assert.same(nil, stream:get_next_chunk())
				end
				local pushed_stream do
					local req_headers = new_headers()
					req_headers:append(":method", "GET")
					req_headers:append(":scheme", "http")
					req_headers:append(":path", "/foo")
					req_headers:append(":authority", "example.com")
					pushed_stream = assert(stream:push_promise(req_headers))
				end
				do
					local req_headers = new_headers()
					req_headers:append(":status", "200")
					assert(pushed_stream:write_headers(req_headers, true))
				end
				assert(s:close())
			end)
			assert_loop(cq, TEST_TIMEOUT)
			assert.truthy(cq:empty())
		end)
		it("handles large header blocks", function()
			local s, c = new_pair()
			local cq = cqueues.new()
			cq:wrap(function()
				local client_stream = c:new_stream()
				local req_headers = new_headers()
				req_headers:append(":method", "GET")
				req_headers:append(":scheme", "http")
				req_headers:append(":path", "/")
				req_headers:append(":authority", "example.com")
				assert(client_stream:write_headers(req_headers, true))
				local pushed_stream = assert(c:get_next_incoming_stream())
				do
					local h = assert(pushed_stream:get_headers())
					assert.same("GET", h:get(":method"))
					assert.same("http", h:get(":scheme"))
					assert.same("/foo", h:get(":path"))
					assert.same(req_headers:get(":authority"), h:get(":authority"))
					assert.same(nil, pushed_stream:get_next_chunk())
				end
				assert(c:close())
			end)
			cq:wrap(function()
				local stream = assert(s:get_next_incoming_stream())
				do
					local h = assert(stream:get_headers())
					assert.same("GET", h:get(":method"))
					assert.same("http", h:get(":scheme"))
					assert.same("/", h:get(":path"))
					assert.same("example.com", h:get(":authority"))
					assert.same(nil, stream:get_next_chunk())
				end
				local pushed_stream do
					local req_headers = new_headers()
					req_headers:append(":method", "GET")
					req_headers:append(":scheme", "http")
					req_headers:append(":path", "/foo")
					req_headers:append(":authority", "example.com")
					req_headers:append("unknown", ("a"):rep(16384*3)) -- at least 3 frames worth
					pushed_stream = assert(stream:push_promise(req_headers))
				end
				do
					local req_headers = new_headers()
					req_headers:append(":status", "200")
					assert(pushed_stream:write_headers(req_headers, true))
				end
				assert(s:close())
			end)
			assert_loop(cq, TEST_TIMEOUT)
			assert.truthy(cq:empty())
		end)
	end)
end)
