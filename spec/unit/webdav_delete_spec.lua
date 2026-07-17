describe("WebDAV deletion", function()
    local WebDav
    local http
    local original_base
    local original_request

    setup(function()
        require("commonrequire")
        http = require("socket.http")
        WebDav = dofile("plugins/cloudstorage.koplugin/providers/webdav.lua")
    end)

    before_each(function()
        original_base = WebDav.base
        original_request = http.request
        WebDav.base = {
            address = "https://dav.example.test/root/",
            username = "alice",
            password = "secret",
        }
    end)

    after_each(function()
        WebDav.base = original_base
        http.request = original_request
        require("socketutil"):reset_timeout()
    end)

    it("sends an authenticated, zero-length DELETE to the encoded item URL", function()
        local captured
        http.request = function(request)
            captured = request
            return 1, 204, {}, "HTTP/1.1 204 No Content"
        end

        local ok, err = WebDav.deleteItem("/Comics/50% #é.cbz")

        assert.is_true(ok)
        assert.is_nil(err)
        assert.equals("DELETE", captured.method)
        assert.equals("https://dav.example.test/root/Comics/50%25%20%23%C3%A9.cbz", captured.url)
        assert.equals("alice", captured.user)
        assert.equals("secret", captured.password)
        assert.equals(0, captured.headers["Content-Length"])
        assert.is_function(captured.sink)
    end)

    it("uses the canonical collection URL when deleting a folder", function()
        local captured
        http.request = function(request)
            captured = request
            return 1, 204, {}, "HTTP/1.1 204 No Content"
        end

        assert.is_true(WebDav.deleteItem("/Comics/Old Series", true))
        assert.equals("https://dav.example.test/root/Comics/Old%20Series/", captured.url)
        assert.equals("infinity", captured.headers.Depth)
    end)

    it("uses the same-origin resource URI returned by PROPFIND", function()
        http.request = function(request)
            request.sink([[<?xml version="1.0"?>
                <d:multistatus xmlns:d="DAV:"><d:response>
                <d:href>/canonical/Comics/Book.cbz</d:href>
                <d:propstat><d:prop><d:resourcetype/>
                <d:getcontentlength>123</d:getcontentlength>
                </d:prop></d:propstat></d:response><d:response>
                <d:href>/canonical/Comics/Not-A-Comic.pdf</d:href>
                <d:propstat><d:prop><d:resourcetype/>
                <d:getcontentlength>456</d:getcontentlength>
                </d:prop></d:propstat></d:response></d:multistatus>]])
            return 1, 207, {}, "HTTP/1.1 207 Multi-Status"
        end

        local items = assert(WebDav.listFolder("/Comics", true))

        assert.equals(1, #items)
        assert.equals("Comics/Book.cbz", items[1].url)
        assert.equals("https://dav.example.test/canonical/Comics/Book.cbz", items[1].dav_url)
    end)

    it("deletes the authoritative resource URI without rebuilding its path", function()
        local captured
        http.request = function(request)
            captured = request
            return 1, 204, {}, "HTTP/1.1 204 No Content"
        end

        assert.is_true(WebDav.deleteItem(
            "/Comics/Book.cbz", false, "https://dav.example.test/canonical/id%2F123"))
        assert.equals("https://dav.example.test/canonical/id%2F123", captured.url)

        local ok, err = WebDav.deleteItem(
            "/Comics/Book.cbz", false, "https://other.example.test/canonical/id%2F123")
        assert.is_nil(ok)
        assert.is_truthy(err:find("unsafe", 1, true))
    end)

    it("follows a method-preserving redirect on the same origin", function()
        local requests = {}
        http.request = function(request)
            table.insert(requests, request)
            if #requests == 1 then
                return 1, 308, { location = "/root/Comics/Book.cbz?canonical=1" },
                    "HTTP/1.1 308 Permanent Redirect"
            end
            return 1, 204, {}, "HTTP/1.1 204 No Content"
        end

        assert.is_true(WebDav.deleteItem("/Comics/Book.cbz"))
        assert.equals(2, #requests)
        assert.equals("DELETE", requests[2].method)
        assert.equals("https://dav.example.test/root/Comics/Book.cbz?canonical=1", requests[2].url)
    end)

    it("refuses a cross-origin DELETE redirect", function()
        http.request = function()
            return 1, 307, { location = "https://other.example.test/Book.cbz" },
                "HTTP/1.1 307 Temporary Redirect"
        end
        local ok, err = WebDav.deleteItem("/Comics/Book.cbz")
        assert.is_nil(ok)
        assert.is_truthy(err:find("refused unsafe", 1, true))
    end)

    it("marks an already absent item without claiming a confirmed deletion", function()
        http.request = function()
            return 1, 404, {}, "HTTP/1.1 404 Not Found"
        end
        local ok, err, already_absent = WebDav.deleteItem("/Comics/Gone.cbz")
        assert.is_true(ok)
        assert.is_nil(err)
        assert.is_true(already_absent)
    end)

    it("reports a failed child in a multi-status response", function()
        http.request = function(request)
            request.sink([[<?xml version="1.0"?>
                <d:multistatus xmlns:d="DAV:"><d:response>
                <d:status>HTTP/1.1 423 Locked</d:status>
                </d:response></d:multistatus>]])
            return 1, 207, {}, "HTTP/1.1 207 Multi-Status"
        end
        local ok, err = WebDav.deleteItem("/Comics/Locked.cbz")
        assert.is_nil(ok)
        assert.is_truthy(err:find("423", 1, true))
    end)

    it("accepts a well-formed all-success multi-status response", function()
        http.request = function(request)
            request.sink([[<d:multistatus xmlns:d="DAV:"><d:response>
                <d:status>HTTP/1.1 204 No Content</d:status>
                </d:response></d:multistatus>]])
            return 1, 207, {}, "HTTP/1.1 207 Multi-Status"
        end
        assert.is_true(WebDav.deleteItem("/Comics/Deleted.cbz"))
    end)

    it("fails closed for empty or malformed multi-status responses", function()
        local bodies = {
            "",
            "<d:multistatus xmlns:d=\"DAV:\"><broken/></d:multistatus>",
            "<d:status>HTTP/1.1 302 Found</d:status>",
        }
        for _, body in ipairs(bodies) do
            http.request = function(request)
                request.sink(body)
                return 1, 207, {}, "HTTP/1.1 207 Multi-Status"
            end
            local ok, err = WebDav.deleteItem("/Comics/Uncertain.cbz")
            assert.is_nil(ok)
            assert.is_truthy(err:find("multi-status", 1, true))
        end
    end)

    it("reports a transport failure", function()
        http.request = function()
            return nil, "connection refused"
        end
        local ok, err = WebDav.deleteItem("/Comics/Offline.cbz")
        assert.is_nil(ok)
        assert.is_truthy(err:find("connection refused", 1, true))
    end)

    it("resets socket timeouts when the request raises an error", function()
        http.request = function()
            error("request crashed")
        end
        local ok, err = WebDav.deleteItem("/Comics/Error.cbz")
        assert.is_nil(ok)
        assert.is_truthy(err:find("request crashed", 1, true))
        local socketutil = require("socketutil")
        assert.equals(socketutil.DEFAULT_BLOCK_TIMEOUT, socketutil.block_timeout)
        assert.equals(socketutil.DEFAULT_TOTAL_TIMEOUT, socketutil.total_timeout)
    end)
end)
