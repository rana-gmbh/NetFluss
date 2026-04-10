var CloudflareSpeedTestRuntime = (() => {
  var __create = Object.create;
  var __defProp = Object.defineProperty;
  var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
  var __getOwnPropNames = Object.getOwnPropertyNames;
  var __getProtoOf = Object.getPrototypeOf;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  var __commonJS = (cb, mod) => function __require() {
    return mod || (0, cb[__getOwnPropNames(cb)[0]])((mod = { exports: {} }).exports, mod), mod.exports;
  };
  var __export = (target, all) => {
    for (var name in all)
      __defProp(target, name, { get: all[name], enumerable: true });
  };
  var __copyProps = (to, from, except, desc) => {
    if (from && typeof from === "object" || typeof from === "function") {
      for (let key of __getOwnPropNames(from))
        if (!__hasOwnProp.call(to, key) && key !== except)
          __defProp(to, key, { get: () => from[key], enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable });
    }
    return to;
  };
  var __toESM = (mod, isNodeMode, target) => (target = mod != null ? __create(__getProtoOf(mod)) : {}, __copyProps(
    // If the importer is in node compatibility mode or this is not an ESM
    // file that has been converted to a CommonJS file using a Babel-
    // compatible transform (i.e. "__esModule" has not been set), then set
    // "default" to the CommonJS "module.exports" for node compatibility.
    isNodeMode || !mod || !mod.__esModule ? __defProp(target, "default", { value: mod, enumerable: true }) : target,
    mod
  ));
  var __toCommonJS = (mod) => __copyProps(__defProp({}, "__esModule", { value: true }), mod);

  // node_modules/whatwg-fetch/dist/fetch.umd.js
  var require_fetch_umd = __commonJS({
    "node_modules/whatwg-fetch/dist/fetch.umd.js"(exports, module) {
      (function(global2, factory) {
        typeof exports === "object" && typeof module !== "undefined" ? factory(exports) : typeof define === "function" && define.amd ? define(["exports"], factory) : factory(global2.WHATWGFetch = {});
      })(exports, (function(exports2) {
        "use strict";
        var g = typeof globalThis !== "undefined" && globalThis || typeof self !== "undefined" && self || // eslint-disable-next-line no-undef
        typeof global !== "undefined" && global || {};
        var support = {
          searchParams: "URLSearchParams" in g,
          iterable: "Symbol" in g && "iterator" in Symbol,
          blob: "FileReader" in g && "Blob" in g && (function() {
            try {
              new Blob();
              return true;
            } catch (e) {
              return false;
            }
          })(),
          formData: "FormData" in g,
          arrayBuffer: "ArrayBuffer" in g
        };
        function isDataView(obj) {
          return obj && DataView.prototype.isPrototypeOf(obj);
        }
        if (support.arrayBuffer) {
          var viewClasses = [
            "[object Int8Array]",
            "[object Uint8Array]",
            "[object Uint8ClampedArray]",
            "[object Int16Array]",
            "[object Uint16Array]",
            "[object Int32Array]",
            "[object Uint32Array]",
            "[object Float32Array]",
            "[object Float64Array]"
          ];
          var isArrayBufferView = ArrayBuffer.isView || function(obj) {
            return obj && viewClasses.indexOf(Object.prototype.toString.call(obj)) > -1;
          };
        }
        function normalizeName(name) {
          if (typeof name !== "string") {
            name = String(name);
          }
          if (/[^a-z0-9\-#$%&'*+.^_`|~!]/i.test(name) || name === "") {
            throw new TypeError('Invalid character in header field name: "' + name + '"');
          }
          return name.toLowerCase();
        }
        function normalizeValue(value) {
          if (typeof value !== "string") {
            value = String(value);
          }
          return value;
        }
        function iteratorFor(items) {
          var iterator = {
            next: function() {
              var value = items.shift();
              return { done: value === void 0, value };
            }
          };
          if (support.iterable) {
            iterator[Symbol.iterator] = function() {
              return iterator;
            };
          }
          return iterator;
        }
        function Headers(headers) {
          this.map = {};
          if (headers instanceof Headers) {
            headers.forEach(function(value, name) {
              this.append(name, value);
            }, this);
          } else if (Array.isArray(headers)) {
            headers.forEach(function(header) {
              if (header.length != 2) {
                throw new TypeError("Headers constructor: expected name/value pair to be length 2, found" + header.length);
              }
              this.append(header[0], header[1]);
            }, this);
          } else if (headers) {
            Object.getOwnPropertyNames(headers).forEach(function(name) {
              this.append(name, headers[name]);
            }, this);
          }
        }
        Headers.prototype.append = function(name, value) {
          name = normalizeName(name);
          value = normalizeValue(value);
          var oldValue = this.map[name];
          this.map[name] = oldValue ? oldValue + ", " + value : value;
        };
        Headers.prototype["delete"] = function(name) {
          delete this.map[normalizeName(name)];
        };
        Headers.prototype.get = function(name) {
          name = normalizeName(name);
          return this.has(name) ? this.map[name] : null;
        };
        Headers.prototype.has = function(name) {
          return this.map.hasOwnProperty(normalizeName(name));
        };
        Headers.prototype.set = function(name, value) {
          this.map[normalizeName(name)] = normalizeValue(value);
        };
        Headers.prototype.forEach = function(callback, thisArg) {
          for (var name in this.map) {
            if (this.map.hasOwnProperty(name)) {
              callback.call(thisArg, this.map[name], name, this);
            }
          }
        };
        Headers.prototype.keys = function() {
          var items = [];
          this.forEach(function(value, name) {
            items.push(name);
          });
          return iteratorFor(items);
        };
        Headers.prototype.values = function() {
          var items = [];
          this.forEach(function(value) {
            items.push(value);
          });
          return iteratorFor(items);
        };
        Headers.prototype.entries = function() {
          var items = [];
          this.forEach(function(value, name) {
            items.push([name, value]);
          });
          return iteratorFor(items);
        };
        if (support.iterable) {
          Headers.prototype[Symbol.iterator] = Headers.prototype.entries;
        }
        function consumed(body) {
          if (body._noBody) return;
          if (body.bodyUsed) {
            return Promise.reject(new TypeError("Already read"));
          }
          body.bodyUsed = true;
        }
        function fileReaderReady(reader) {
          return new Promise(function(resolve, reject) {
            reader.onload = function() {
              resolve(reader.result);
            };
            reader.onerror = function() {
              reject(reader.error);
            };
          });
        }
        function readBlobAsArrayBuffer(blob) {
          var reader = new FileReader();
          var promise = fileReaderReady(reader);
          reader.readAsArrayBuffer(blob);
          return promise;
        }
        function readBlobAsText(blob) {
          var reader = new FileReader();
          var promise = fileReaderReady(reader);
          var match = /charset=([A-Za-z0-9_-]+)/.exec(blob.type);
          var encoding = match ? match[1] : "utf-8";
          reader.readAsText(blob, encoding);
          return promise;
        }
        function readArrayBufferAsText(buf) {
          var view = new Uint8Array(buf);
          var chars = new Array(view.length);
          for (var i = 0; i < view.length; i++) {
            chars[i] = String.fromCharCode(view[i]);
          }
          return chars.join("");
        }
        function bufferClone(buf) {
          if (buf.slice) {
            return buf.slice(0);
          } else {
            var view = new Uint8Array(buf.byteLength);
            view.set(new Uint8Array(buf));
            return view.buffer;
          }
        }
        function Body() {
          this.bodyUsed = false;
          this._initBody = function(body) {
            this.bodyUsed = this.bodyUsed;
            this._bodyInit = body;
            if (!body) {
              this._noBody = true;
              this._bodyText = "";
            } else if (typeof body === "string") {
              this._bodyText = body;
            } else if (support.blob && Blob.prototype.isPrototypeOf(body)) {
              this._bodyBlob = body;
            } else if (support.formData && FormData.prototype.isPrototypeOf(body)) {
              this._bodyFormData = body;
            } else if (support.searchParams && URLSearchParams.prototype.isPrototypeOf(body)) {
              this._bodyText = body.toString();
            } else if (support.arrayBuffer && support.blob && isDataView(body)) {
              this._bodyArrayBuffer = bufferClone(body.buffer);
              this._bodyInit = new Blob([this._bodyArrayBuffer]);
            } else if (support.arrayBuffer && (ArrayBuffer.prototype.isPrototypeOf(body) || isArrayBufferView(body))) {
              this._bodyArrayBuffer = bufferClone(body);
            } else {
              this._bodyText = body = Object.prototype.toString.call(body);
            }
            if (!this.headers.get("content-type")) {
              if (typeof body === "string") {
                this.headers.set("content-type", "text/plain;charset=UTF-8");
              } else if (this._bodyBlob && this._bodyBlob.type) {
                this.headers.set("content-type", this._bodyBlob.type);
              } else if (support.searchParams && URLSearchParams.prototype.isPrototypeOf(body)) {
                this.headers.set("content-type", "application/x-www-form-urlencoded;charset=UTF-8");
              }
            }
          };
          if (support.blob) {
            this.blob = function() {
              var rejected = consumed(this);
              if (rejected) {
                return rejected;
              }
              if (this._bodyBlob) {
                return Promise.resolve(this._bodyBlob);
              } else if (this._bodyArrayBuffer) {
                return Promise.resolve(new Blob([this._bodyArrayBuffer]));
              } else if (this._bodyFormData) {
                throw new Error("could not read FormData body as blob");
              } else {
                return Promise.resolve(new Blob([this._bodyText]));
              }
            };
          }
          this.arrayBuffer = function() {
            if (this._bodyArrayBuffer) {
              var isConsumed = consumed(this);
              if (isConsumed) {
                return isConsumed;
              } else if (ArrayBuffer.isView(this._bodyArrayBuffer)) {
                return Promise.resolve(
                  this._bodyArrayBuffer.buffer.slice(
                    this._bodyArrayBuffer.byteOffset,
                    this._bodyArrayBuffer.byteOffset + this._bodyArrayBuffer.byteLength
                  )
                );
              } else {
                return Promise.resolve(this._bodyArrayBuffer);
              }
            } else if (support.blob) {
              return this.blob().then(readBlobAsArrayBuffer);
            } else {
              throw new Error("could not read as ArrayBuffer");
            }
          };
          this.text = function() {
            var rejected = consumed(this);
            if (rejected) {
              return rejected;
            }
            if (this._bodyBlob) {
              return readBlobAsText(this._bodyBlob);
            } else if (this._bodyArrayBuffer) {
              return Promise.resolve(readArrayBufferAsText(this._bodyArrayBuffer));
            } else if (this._bodyFormData) {
              throw new Error("could not read FormData body as text");
            } else {
              return Promise.resolve(this._bodyText);
            }
          };
          if (support.formData) {
            this.formData = function() {
              return this.text().then(decode);
            };
          }
          this.json = function() {
            return this.text().then(JSON.parse);
          };
          return this;
        }
        var methods = ["CONNECT", "DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT", "TRACE"];
        function normalizeMethod(method) {
          var upcased = method.toUpperCase();
          return methods.indexOf(upcased) > -1 ? upcased : method;
        }
        function Request(input, options) {
          if (!(this instanceof Request)) {
            throw new TypeError('Please use the "new" operator, this DOM object constructor cannot be called as a function.');
          }
          options = options || {};
          var body = options.body;
          if (input instanceof Request) {
            if (input.bodyUsed) {
              throw new TypeError("Already read");
            }
            this.url = input.url;
            this.credentials = input.credentials;
            if (!options.headers) {
              this.headers = new Headers(input.headers);
            }
            this.method = input.method;
            this.mode = input.mode;
            this.signal = input.signal;
            if (!body && input._bodyInit != null) {
              body = input._bodyInit;
              input.bodyUsed = true;
            }
          } else {
            this.url = String(input);
          }
          this.credentials = options.credentials || this.credentials || "same-origin";
          if (options.headers || !this.headers) {
            this.headers = new Headers(options.headers);
          }
          this.method = normalizeMethod(options.method || this.method || "GET");
          this.mode = options.mode || this.mode || null;
          this.signal = options.signal || this.signal || (function() {
            if ("AbortController" in g) {
              var ctrl = new AbortController();
              return ctrl.signal;
            }
          })();
          this.referrer = null;
          if ((this.method === "GET" || this.method === "HEAD") && body) {
            throw new TypeError("Body not allowed for GET or HEAD requests");
          }
          this._initBody(body);
          if (this.method === "GET" || this.method === "HEAD") {
            if (options.cache === "no-store" || options.cache === "no-cache") {
              var reParamSearch = /([?&])_=[^&]*/;
              if (reParamSearch.test(this.url)) {
                this.url = this.url.replace(reParamSearch, "$1_=" + (/* @__PURE__ */ new Date()).getTime());
              } else {
                var reQueryString = /\?/;
                this.url += (reQueryString.test(this.url) ? "&" : "?") + "_=" + (/* @__PURE__ */ new Date()).getTime();
              }
            }
          }
        }
        Request.prototype.clone = function() {
          return new Request(this, { body: this._bodyInit });
        };
        function decode(body) {
          var form = new FormData();
          body.trim().split("&").forEach(function(bytes) {
            if (bytes) {
              var split = bytes.split("=");
              var name = split.shift().replace(/\+/g, " ");
              var value = split.join("=").replace(/\+/g, " ");
              form.append(decodeURIComponent(name), decodeURIComponent(value));
            }
          });
          return form;
        }
        function parseHeaders(rawHeaders) {
          var headers = new Headers();
          var preProcessedHeaders = rawHeaders.replace(/\r?\n[\t ]+/g, " ");
          preProcessedHeaders.split("\r").map(function(header) {
            return header.indexOf("\n") === 0 ? header.substr(1, header.length) : header;
          }).forEach(function(line) {
            var parts = line.split(":");
            var key = parts.shift().trim();
            if (key) {
              var value = parts.join(":").trim();
              try {
                headers.append(key, value);
              } catch (error) {
                console.warn("Response " + error.message);
              }
            }
          });
          return headers;
        }
        Body.call(Request.prototype);
        function Response(bodyInit, options) {
          if (!(this instanceof Response)) {
            throw new TypeError('Please use the "new" operator, this DOM object constructor cannot be called as a function.');
          }
          if (!options) {
            options = {};
          }
          this.type = "default";
          this.status = options.status === void 0 ? 200 : options.status;
          if (this.status < 200 || this.status > 599) {
            throw new RangeError("Failed to construct 'Response': The status provided (0) is outside the range [200, 599].");
          }
          this.ok = this.status >= 200 && this.status < 300;
          this.statusText = options.statusText === void 0 ? "" : "" + options.statusText;
          this.headers = new Headers(options.headers);
          this.url = options.url || "";
          this._initBody(bodyInit);
        }
        Body.call(Response.prototype);
        Response.prototype.clone = function() {
          return new Response(this._bodyInit, {
            status: this.status,
            statusText: this.statusText,
            headers: new Headers(this.headers),
            url: this.url
          });
        };
        Response.error = function() {
          var response = new Response(null, { status: 200, statusText: "" });
          response.ok = false;
          response.status = 0;
          response.type = "error";
          return response;
        };
        var redirectStatuses = [301, 302, 303, 307, 308];
        Response.redirect = function(url, status) {
          if (redirectStatuses.indexOf(status) === -1) {
            throw new RangeError("Invalid status code");
          }
          return new Response(null, { status, headers: { location: url } });
        };
        exports2.DOMException = g.DOMException;
        try {
          new exports2.DOMException();
        } catch (err) {
          exports2.DOMException = function(message, name) {
            this.message = message;
            this.name = name;
            var error = Error(message);
            this.stack = error.stack;
          };
          exports2.DOMException.prototype = Object.create(Error.prototype);
          exports2.DOMException.prototype.constructor = exports2.DOMException;
        }
        function fetch2(input, init) {
          return new Promise(function(resolve, reject) {
            var request = new Request(input, init);
            if (request.signal && request.signal.aborted) {
              return reject(new exports2.DOMException("Aborted", "AbortError"));
            }
            var xhr = new XMLHttpRequest();
            function abortXhr() {
              xhr.abort();
            }
            xhr.onload = function() {
              var options = {
                statusText: xhr.statusText,
                headers: parseHeaders(xhr.getAllResponseHeaders() || "")
              };
              if (request.url.indexOf("file://") === 0 && (xhr.status < 200 || xhr.status > 599)) {
                options.status = 200;
              } else {
                options.status = xhr.status;
              }
              options.url = "responseURL" in xhr ? xhr.responseURL : options.headers.get("X-Request-URL");
              var body = "response" in xhr ? xhr.response : xhr.responseText;
              setTimeout(function() {
                resolve(new Response(body, options));
              }, 0);
            };
            xhr.onerror = function() {
              setTimeout(function() {
                reject(new TypeError("Network request failed"));
              }, 0);
            };
            xhr.ontimeout = function() {
              setTimeout(function() {
                reject(new TypeError("Network request timed out"));
              }, 0);
            };
            xhr.onabort = function() {
              setTimeout(function() {
                reject(new exports2.DOMException("Aborted", "AbortError"));
              }, 0);
            };
            function fixUrl(url) {
              try {
                return url === "" && g.location.href ? g.location.href : url;
              } catch (e) {
                return url;
              }
            }
            xhr.open(request.method, fixUrl(request.url), true);
            if (request.credentials === "include") {
              xhr.withCredentials = true;
            } else if (request.credentials === "omit") {
              xhr.withCredentials = false;
            }
            if ("responseType" in xhr) {
              if (support.blob) {
                xhr.responseType = "blob";
              } else if (support.arrayBuffer) {
                xhr.responseType = "arraybuffer";
              }
            }
            if (init && typeof init.headers === "object" && !(init.headers instanceof Headers || g.Headers && init.headers instanceof g.Headers)) {
              var names = [];
              Object.getOwnPropertyNames(init.headers).forEach(function(name) {
                names.push(normalizeName(name));
                xhr.setRequestHeader(name, normalizeValue(init.headers[name]));
              });
              request.headers.forEach(function(value, name) {
                if (names.indexOf(name) === -1) {
                  xhr.setRequestHeader(name, value);
                }
              });
            } else {
              request.headers.forEach(function(value, name) {
                xhr.setRequestHeader(name, value);
              });
            }
            if (request.signal) {
              request.signal.addEventListener("abort", abortXhr);
              xhr.onreadystatechange = function() {
                if (xhr.readyState === 4) {
                  request.signal.removeEventListener("abort", abortXhr);
                }
              };
            }
            xhr.send(typeof request._bodyInit === "undefined" ? null : request._bodyInit);
          });
        }
        fetch2.polyfill = true;
        if (!g.fetch) {
          g.fetch = fetch2;
          g.Headers = Headers;
          g.Request = Request;
          g.Response = Response;
        }
        exports2.Headers = Headers;
        exports2.Request = Request;
        exports2.Response = Response;
        exports2.fetch = fetch2;
        Object.defineProperty(exports2, "__esModule", { value: true });
      }));
    }
  });

  // node_modules/isomorphic-fetch/fetch-npm-browserify.js
  var require_fetch_npm_browserify = __commonJS({
    "node_modules/isomorphic-fetch/fetch-npm-browserify.js"(exports, module) {
      require_fetch_umd();
      module.exports = self.fetch.bind(self);
    }
  });

  // node_modules/lodash.memoize/index.js
  var require_lodash = __commonJS({
    "node_modules/lodash.memoize/index.js"(exports, module) {
      var FUNC_ERROR_TEXT = "Expected a function";
      var HASH_UNDEFINED = "__lodash_hash_undefined__";
      var funcTag = "[object Function]";
      var genTag = "[object GeneratorFunction]";
      var reRegExpChar = /[\\^$.*+?()[\]{}|]/g;
      var reIsHostCtor = /^\[object .+?Constructor\]$/;
      var freeGlobal = typeof global == "object" && global && global.Object === Object && global;
      var freeSelf = typeof self == "object" && self && self.Object === Object && self;
      var root = freeGlobal || freeSelf || Function("return this")();
      function getValue(object, key) {
        return object == null ? void 0 : object[key];
      }
      function isHostObject(value) {
        var result = false;
        if (value != null && typeof value.toString != "function") {
          try {
            result = !!(value + "");
          } catch (e) {
          }
        }
        return result;
      }
      var arrayProto = Array.prototype;
      var funcProto = Function.prototype;
      var objectProto = Object.prototype;
      var coreJsData = root["__core-js_shared__"];
      var maskSrcKey = (function() {
        var uid = /[^.]+$/.exec(coreJsData && coreJsData.keys && coreJsData.keys.IE_PROTO || "");
        return uid ? "Symbol(src)_1." + uid : "";
      })();
      var funcToString = funcProto.toString;
      var hasOwnProperty = objectProto.hasOwnProperty;
      var objectToString = objectProto.toString;
      var reIsNative = RegExp(
        "^" + funcToString.call(hasOwnProperty).replace(reRegExpChar, "\\$&").replace(/hasOwnProperty|(function).*?(?=\\\()| for .+?(?=\\\])/g, "$1.*?") + "$"
      );
      var splice = arrayProto.splice;
      var Map = getNative(root, "Map");
      var nativeCreate = getNative(Object, "create");
      function Hash(entries) {
        var index = -1, length = entries ? entries.length : 0;
        this.clear();
        while (++index < length) {
          var entry = entries[index];
          this.set(entry[0], entry[1]);
        }
      }
      function hashClear() {
        this.__data__ = nativeCreate ? nativeCreate(null) : {};
      }
      function hashDelete(key) {
        return this.has(key) && delete this.__data__[key];
      }
      function hashGet(key) {
        var data = this.__data__;
        if (nativeCreate) {
          var result = data[key];
          return result === HASH_UNDEFINED ? void 0 : result;
        }
        return hasOwnProperty.call(data, key) ? data[key] : void 0;
      }
      function hashHas(key) {
        var data = this.__data__;
        return nativeCreate ? data[key] !== void 0 : hasOwnProperty.call(data, key);
      }
      function hashSet(key, value) {
        var data = this.__data__;
        data[key] = nativeCreate && value === void 0 ? HASH_UNDEFINED : value;
        return this;
      }
      Hash.prototype.clear = hashClear;
      Hash.prototype["delete"] = hashDelete;
      Hash.prototype.get = hashGet;
      Hash.prototype.has = hashHas;
      Hash.prototype.set = hashSet;
      function ListCache(entries) {
        var index = -1, length = entries ? entries.length : 0;
        this.clear();
        while (++index < length) {
          var entry = entries[index];
          this.set(entry[0], entry[1]);
        }
      }
      function listCacheClear() {
        this.__data__ = [];
      }
      function listCacheDelete(key) {
        var data = this.__data__, index = assocIndexOf(data, key);
        if (index < 0) {
          return false;
        }
        var lastIndex = data.length - 1;
        if (index == lastIndex) {
          data.pop();
        } else {
          splice.call(data, index, 1);
        }
        return true;
      }
      function listCacheGet(key) {
        var data = this.__data__, index = assocIndexOf(data, key);
        return index < 0 ? void 0 : data[index][1];
      }
      function listCacheHas(key) {
        return assocIndexOf(this.__data__, key) > -1;
      }
      function listCacheSet(key, value) {
        var data = this.__data__, index = assocIndexOf(data, key);
        if (index < 0) {
          data.push([key, value]);
        } else {
          data[index][1] = value;
        }
        return this;
      }
      ListCache.prototype.clear = listCacheClear;
      ListCache.prototype["delete"] = listCacheDelete;
      ListCache.prototype.get = listCacheGet;
      ListCache.prototype.has = listCacheHas;
      ListCache.prototype.set = listCacheSet;
      function MapCache(entries) {
        var index = -1, length = entries ? entries.length : 0;
        this.clear();
        while (++index < length) {
          var entry = entries[index];
          this.set(entry[0], entry[1]);
        }
      }
      function mapCacheClear() {
        this.__data__ = {
          "hash": new Hash(),
          "map": new (Map || ListCache)(),
          "string": new Hash()
        };
      }
      function mapCacheDelete(key) {
        return getMapData(this, key)["delete"](key);
      }
      function mapCacheGet(key) {
        return getMapData(this, key).get(key);
      }
      function mapCacheHas(key) {
        return getMapData(this, key).has(key);
      }
      function mapCacheSet(key, value) {
        getMapData(this, key).set(key, value);
        return this;
      }
      MapCache.prototype.clear = mapCacheClear;
      MapCache.prototype["delete"] = mapCacheDelete;
      MapCache.prototype.get = mapCacheGet;
      MapCache.prototype.has = mapCacheHas;
      MapCache.prototype.set = mapCacheSet;
      function assocIndexOf(array, key) {
        var length = array.length;
        while (length--) {
          if (eq(array[length][0], key)) {
            return length;
          }
        }
        return -1;
      }
      function baseIsNative(value) {
        if (!isObject(value) || isMasked(value)) {
          return false;
        }
        var pattern = isFunction(value) || isHostObject(value) ? reIsNative : reIsHostCtor;
        return pattern.test(toSource(value));
      }
      function getMapData(map, key) {
        var data = map.__data__;
        return isKeyable(key) ? data[typeof key == "string" ? "string" : "hash"] : data.map;
      }
      function getNative(object, key) {
        var value = getValue(object, key);
        return baseIsNative(value) ? value : void 0;
      }
      function isKeyable(value) {
        var type = typeof value;
        return type == "string" || type == "number" || type == "symbol" || type == "boolean" ? value !== "__proto__" : value === null;
      }
      function isMasked(func) {
        return !!maskSrcKey && maskSrcKey in func;
      }
      function toSource(func) {
        if (func != null) {
          try {
            return funcToString.call(func);
          } catch (e) {
          }
          try {
            return func + "";
          } catch (e) {
          }
        }
        return "";
      }
      function memoize2(func, resolver) {
        if (typeof func != "function" || resolver && typeof resolver != "function") {
          throw new TypeError(FUNC_ERROR_TEXT);
        }
        var memoized = function() {
          var args = arguments, key = resolver ? resolver.apply(this, args) : args[0], cache = memoized.cache;
          if (cache.has(key)) {
            return cache.get(key);
          }
          var result = func.apply(this, args);
          memoized.cache = cache.set(key, result);
          return result;
        };
        memoized.cache = new (memoize2.Cache || MapCache)();
        return memoized;
      }
      memoize2.Cache = MapCache;
      function eq(value, other) {
        return value === other || value !== value && other !== other;
      }
      function isFunction(value) {
        var tag = isObject(value) ? objectToString.call(value) : "";
        return tag == funcTag || tag == genTag;
      }
      function isObject(value) {
        var type = typeof value;
        return !!value && (type == "object" || type == "function");
      }
      module.exports = memoize2;
    }
  });

  // node_modules/@cloudflare/speedtest/dist/speedtest.js
  var speedtest_exports = {};
  __export(speedtest_exports, {
    default: () => LoggingMeasurementEngine
  });
  var import_isomorphic_fetch = __toESM(require_fetch_npm_browserify(), 1);
  var import_lodash = __toESM(require_lodash(), 1);

  // node_modules/d3-array/src/ascending.js
  function ascending(a, b) {
    return a == null || b == null ? NaN : a < b ? -1 : a > b ? 1 : a >= b ? 0 : NaN;
  }

  // node_modules/d3-array/src/descending.js
  function descending(a, b) {
    return a == null || b == null ? NaN : b < a ? -1 : b > a ? 1 : b >= a ? 0 : NaN;
  }

  // node_modules/d3-array/src/bisector.js
  function bisector(f) {
    let compare1, compare2, delta;
    if (f.length !== 2) {
      compare1 = ascending;
      compare2 = (d, x) => ascending(f(d), x);
      delta = (d, x) => f(d) - x;
    } else {
      compare1 = f === ascending || f === descending ? f : zero;
      compare2 = f;
      delta = f;
    }
    function left(a, x, lo = 0, hi = a.length) {
      if (lo < hi) {
        if (compare1(x, x) !== 0) return hi;
        do {
          const mid = lo + hi >>> 1;
          if (compare2(a[mid], x) < 0) lo = mid + 1;
          else hi = mid;
        } while (lo < hi);
      }
      return lo;
    }
    function right(a, x, lo = 0, hi = a.length) {
      if (lo < hi) {
        if (compare1(x, x) !== 0) return hi;
        do {
          const mid = lo + hi >>> 1;
          if (compare2(a[mid], x) <= 0) lo = mid + 1;
          else hi = mid;
        } while (lo < hi);
      }
      return lo;
    }
    function center(a, x, lo = 0, hi = a.length) {
      const i = left(a, x, lo, hi - 1);
      return i > lo && delta(a[i - 1], x) > -delta(a[i], x) ? i - 1 : i;
    }
    return { left, center, right };
  }
  function zero() {
    return 0;
  }

  // node_modules/d3-array/src/number.js
  function number(x) {
    return x === null ? NaN : +x;
  }

  // node_modules/d3-array/src/bisect.js
  var ascendingBisect = bisector(ascending);
  var bisectRight = ascendingBisect.right;
  var bisectLeft = ascendingBisect.left;
  var bisectCenter = bisector(number).center;
  var bisect_default = bisectRight;

  // node_modules/d3-scale/src/init.js
  function initRange(domain, range) {
    switch (arguments.length) {
      case 0:
        break;
      case 1:
        this.range(domain);
        break;
      default:
        this.range(range).domain(domain);
        break;
    }
    return this;
  }

  // node_modules/d3-scale/src/threshold.js
  function threshold() {
    var domain = [0.5], range = [0, 1], unknown, n = 1;
    function scale(x) {
      return x != null && x <= x ? range[bisect_default(domain, x, 0, n)] : unknown;
    }
    scale.domain = function(_) {
      return arguments.length ? (domain = Array.from(_), n = Math.min(domain.length, range.length - 1), scale) : domain.slice();
    };
    scale.range = function(_) {
      return arguments.length ? (range = Array.from(_), n = Math.min(domain.length, range.length - 1), scale) : range.slice();
    };
    scale.invertExtent = function(y) {
      var i = range.indexOf(y);
      return [domain[i - 1], domain[i]];
    };
    scale.unknown = function(_) {
      return arguments.length ? (unknown = _, scale) : unknown;
    };
    scale.copy = function() {
      return threshold().domain(domain).range(range).unknown(unknown);
    };
    return initRange.apply(scale, arguments);
  }

  // node_modules/@cloudflare/speedtest/dist/speedtest.js
  function _arrayLikeToArray(r, a) {
    (null == a || a > r.length) && (a = r.length);
    for (var e = 0, n = Array(a); e < a; e++) n[e] = r[e];
    return n;
  }
  function _arrayWithHoles(r) {
    if (Array.isArray(r)) return r;
  }
  function _arrayWithoutHoles(r) {
    if (Array.isArray(r)) return _arrayLikeToArray(r);
  }
  function _assertClassBrand(e, t, n) {
    if ("function" == typeof e ? e === t : e.has(t)) return arguments.length < 3 ? t : n;
    throw new TypeError("Private element is not present on this object");
  }
  function _assertThisInitialized(e) {
    if (void 0 === e) throw new ReferenceError("this hasn't been initialised - super() hasn't been called");
    return e;
  }
  function _callSuper(t, o, e) {
    return o = _getPrototypeOf(o), _possibleConstructorReturn(t, _isNativeReflectConstruct() ? Reflect.construct(o, e || [], _getPrototypeOf(t).constructor) : o.apply(t, e));
  }
  function _checkPrivateRedeclaration(e, t) {
    if (t.has(e)) throw new TypeError("Cannot initialize the same private elements twice on an object");
  }
  function _classCallCheck(a, n) {
    if (!(a instanceof n)) throw new TypeError("Cannot call a class as a function");
  }
  function _classPrivateFieldGet2(s, a) {
    return s.get(_assertClassBrand(s, a));
  }
  function _classPrivateFieldInitSpec(e, t, a) {
    _checkPrivateRedeclaration(e, t), t.set(e, a);
  }
  function _classPrivateFieldSet2(s, a, r) {
    return s.set(_assertClassBrand(s, a), r), r;
  }
  function _classPrivateMethodInitSpec(e, a) {
    _checkPrivateRedeclaration(e, a), a.add(e);
  }
  function _defineProperties(e, r) {
    for (var t = 0; t < r.length; t++) {
      var o = r[t];
      o.enumerable = o.enumerable || false, o.configurable = true, "value" in o && (o.writable = true), Object.defineProperty(e, _toPropertyKey(o.key), o);
    }
  }
  function _createClass(e, r, t) {
    return r && _defineProperties(e.prototype, r), Object.defineProperty(e, "prototype", {
      writable: false
    }), e;
  }
  function _defineProperty(e, r, t) {
    return (r = _toPropertyKey(r)) in e ? Object.defineProperty(e, r, {
      value: t,
      enumerable: true,
      configurable: true,
      writable: true
    }) : e[r] = t, e;
  }
  function _get() {
    return _get = "undefined" != typeof Reflect && Reflect.get ? Reflect.get.bind() : function(e, t, r) {
      var p = _superPropBase(e, t);
      if (p) {
        var n = Object.getOwnPropertyDescriptor(p, t);
        return n.get ? n.get.call(arguments.length < 3 ? e : r) : n.value;
      }
    }, _get.apply(null, arguments);
  }
  function _getPrototypeOf(t) {
    return _getPrototypeOf = Object.setPrototypeOf ? Object.getPrototypeOf.bind() : function(t2) {
      return t2.__proto__ || Object.getPrototypeOf(t2);
    }, _getPrototypeOf(t);
  }
  function _inherits(t, e) {
    if ("function" != typeof e && null !== e) throw new TypeError("Super expression must either be null or a function");
    t.prototype = Object.create(e && e.prototype, {
      constructor: {
        value: t,
        writable: true,
        configurable: true
      }
    }), Object.defineProperty(t, "prototype", {
      writable: false
    }), e && _setPrototypeOf(t, e);
  }
  function _isNativeReflectConstruct() {
    try {
      var t = !Boolean.prototype.valueOf.call(Reflect.construct(Boolean, [], function() {
      }));
    } catch (t2) {
    }
    return (_isNativeReflectConstruct = function() {
      return !!t;
    })();
  }
  function _iterableToArray(r) {
    if ("undefined" != typeof Symbol && null != r[Symbol.iterator] || null != r["@@iterator"]) return Array.from(r);
  }
  function _iterableToArrayLimit(r, l) {
    var t = null == r ? null : "undefined" != typeof Symbol && r[Symbol.iterator] || r["@@iterator"];
    if (null != t) {
      var e, n, i, u, a = [], f = true, o = false;
      try {
        if (i = (t = t.call(r)).next, 0 === l) {
          if (Object(t) !== t) return;
          f = false;
        } else for (; !(f = (e = i.call(t)).done) && (a.push(e.value), a.length !== l); f = true) ;
      } catch (r2) {
        o = true, n = r2;
      } finally {
        try {
          if (!f && null != t.return && (u = t.return(), Object(u) !== u)) return;
        } finally {
          if (o) throw n;
        }
      }
      return a;
    }
  }
  function _nonIterableRest() {
    throw new TypeError("Invalid attempt to destructure non-iterable instance.\nIn order to be iterable, non-array objects must have a [Symbol.iterator]() method.");
  }
  function _nonIterableSpread() {
    throw new TypeError("Invalid attempt to spread non-iterable instance.\nIn order to be iterable, non-array objects must have a [Symbol.iterator]() method.");
  }
  function ownKeys(e, r) {
    var t = Object.keys(e);
    if (Object.getOwnPropertySymbols) {
      var o = Object.getOwnPropertySymbols(e);
      r && (o = o.filter(function(r2) {
        return Object.getOwnPropertyDescriptor(e, r2).enumerable;
      })), t.push.apply(t, o);
    }
    return t;
  }
  function _objectSpread2(e) {
    for (var r = 1; r < arguments.length; r++) {
      var t = null != arguments[r] ? arguments[r] : {};
      r % 2 ? ownKeys(Object(t), true).forEach(function(r2) {
        _defineProperty(e, r2, t[r2]);
      }) : Object.getOwnPropertyDescriptors ? Object.defineProperties(e, Object.getOwnPropertyDescriptors(t)) : ownKeys(Object(t)).forEach(function(r2) {
        Object.defineProperty(e, r2, Object.getOwnPropertyDescriptor(t, r2));
      });
    }
    return e;
  }
  function _objectWithoutProperties(e, t) {
    if (null == e) return {};
    var o, r, i = _objectWithoutPropertiesLoose(e, t);
    if (Object.getOwnPropertySymbols) {
      var n = Object.getOwnPropertySymbols(e);
      for (r = 0; r < n.length; r++) o = n[r], -1 === t.indexOf(o) && {}.propertyIsEnumerable.call(e, o) && (i[o] = e[o]);
    }
    return i;
  }
  function _objectWithoutPropertiesLoose(r, e) {
    if (null == r) return {};
    var t = {};
    for (var n in r) if ({}.hasOwnProperty.call(r, n)) {
      if (-1 !== e.indexOf(n)) continue;
      t[n] = r[n];
    }
    return t;
  }
  function _possibleConstructorReturn(t, e) {
    if (e && ("object" == typeof e || "function" == typeof e)) return e;
    if (void 0 !== e) throw new TypeError("Derived constructors may only return object or undefined");
    return _assertThisInitialized(t);
  }
  function set(e, r, t, o) {
    return set = "undefined" != typeof Reflect && Reflect.set ? Reflect.set : function(e2, r2, t2, o2) {
      var f, i = _superPropBase(e2, r2);
      if (i) {
        if ((f = Object.getOwnPropertyDescriptor(i, r2)).set) return f.set.call(o2, t2), true;
        if (!f.writable) return false;
      }
      if (f = Object.getOwnPropertyDescriptor(o2, r2)) {
        if (!f.writable) return false;
        f.value = t2, Object.defineProperty(o2, r2, f);
      } else _defineProperty(o2, r2, t2);
      return true;
    }, set(e, r, t, o);
  }
  function _set(e, r, t, o, f) {
    if (!set(e, r, t, o || e) && f) throw new TypeError("failed to set property");
    return t;
  }
  function _setPrototypeOf(t, e) {
    return _setPrototypeOf = Object.setPrototypeOf ? Object.setPrototypeOf.bind() : function(t2, e2) {
      return t2.__proto__ = e2, t2;
    }, _setPrototypeOf(t, e);
  }
  function _slicedToArray(r, e) {
    return _arrayWithHoles(r) || _iterableToArrayLimit(r, e) || _unsupportedIterableToArray(r, e) || _nonIterableRest();
  }
  function _superPropBase(t, o) {
    for (; !{}.hasOwnProperty.call(t, o) && null !== (t = _getPrototypeOf(t)); ) ;
    return t;
  }
  function _superPropGet(t, o, e, r) {
    var p = _get(_getPrototypeOf(t.prototype), o, e);
    return 2 & r && "function" == typeof p ? function(t2) {
      return p.apply(e, t2);
    } : p;
  }
  function _superPropSet(t, e, o, r, p, f) {
    return _set(_getPrototypeOf(t.prototype), e, o, r, p);
  }
  function _toConsumableArray(r) {
    return _arrayWithoutHoles(r) || _iterableToArray(r) || _unsupportedIterableToArray(r) || _nonIterableSpread();
  }
  function _toPrimitive(t, r) {
    if ("object" != typeof t || !t) return t;
    var e = t[Symbol.toPrimitive];
    if (void 0 !== e) {
      var i = e.call(t, r);
      if ("object" != typeof i) return i;
      throw new TypeError("@@toPrimitive must return a primitive value.");
    }
    return String(t);
  }
  function _toPropertyKey(t) {
    var i = _toPrimitive(t, "string");
    return "symbol" == typeof i ? i : i + "";
  }
  function _unsupportedIterableToArray(r, a) {
    if (r) {
      if ("string" == typeof r) return _arrayLikeToArray(r, a);
      var t = {}.toString.call(r).slice(8, -1);
      return "Object" === t && r.constructor && (t = r.constructor.name), "Map" === t || "Set" === t ? Array.from(r) : "Arguments" === t || /^(?:Ui|I)nt(?:8|16|32)(?:Clamped)?Array$/.test(t) ? _arrayLikeToArray(r, a) : void 0;
    }
  }
  var REL_API_URL = "https://speed.cloudflare.com";
  var defaultConfig = {
    // Engine
    autoStart: true,
    // APIs
    downloadApiUrl: "".concat(REL_API_URL, "/__down"),
    uploadApiUrl: "".concat(REL_API_URL, "/__up"),
    logMeasurementApiUrl: null,
    logAimApiUrl: "https://aim.cloudflare.com/__log",
    turnServerUri: "turn.speed.cloudflare.com:50000",
    turnServerCredsApiUrl: "".concat(REL_API_URL, "/turn-creds"),
    turnServerUser: null,
    turnServerPass: null,
    rpkiInvalidHost: "invalid.rpki.cloudflare.com",
    cfTraceUrl: "".concat(REL_API_URL, "/cdn-cgi/trace"),
    includeCredentials: false,
    sessionId: void 0,
    // Measurements
    measurements: [
      {
        type: "latency",
        numPackets: 1
      },
      // initial ttfb estimation
      {
        type: "download",
        bytes: 1e5,
        count: 1,
        bypassMinDuration: true
      },
      // initial download estimation
      {
        type: "latency",
        numPackets: 20
      },
      {
        type: "download",
        bytes: 1e5,
        count: 9
      },
      {
        type: "download",
        bytes: 1e6,
        count: 8
      },
      {
        type: "upload",
        bytes: 1e5,
        count: 8
      },
      {
        type: "packetLoss",
        numPackets: 1e3,
        batchSize: 10,
        batchWaitTime: 10,
        // ms (in between batches)
        responsesWaitTime: 3e3
        // ms (silent time after last sent msg)
      },
      {
        type: "upload",
        bytes: 1e6,
        count: 6
      },
      {
        type: "download",
        bytes: 1e7,
        count: 6
      },
      {
        type: "upload",
        bytes: 1e7,
        count: 4
      },
      {
        type: "download",
        bytes: 25e6,
        count: 4
      },
      {
        type: "upload",
        bytes: 25e6,
        count: 4
      },
      {
        type: "download",
        bytes: 1e8,
        count: 3
      },
      {
        type: "upload",
        bytes: 5e7,
        count: 3
      },
      {
        type: "download",
        bytes: 25e7,
        count: 2
      }
    ],
    measureDownloadLoadedLatency: true,
    measureUploadLoadedLatency: true,
    loadedLatencyThrottle: 400,
    // ms in between loaded latency requests
    bandwidthFinishRequestDuration: 1e3,
    // download/upload duration (ms) to reach for stopping further measurements of that type
    estimatedServerTime: 10,
    // ms to discount from latency calculation (if not present in response headers)
    // Test abort
    bandwidthAbortRequestDuration: 0,
    // download/upload duration (ms) to abort measurement early and stop further measurements of that type
    // Result interpretation
    latencyPercentile: 0.5,
    // Percentile used to calculate latency from a set of measurements
    bandwidthPercentile: 0.9,
    // Percentile used to calculate bandwidth from a set of measurements
    bandwidthMinRequestDuration: 10,
    // minimum duration (ms) to consider a measurement good enough to use in bandwidth calculation
    loadedRequestMinDuration: 250,
    // minimum duration (ms) of a request to consider it to be loading the connection
    loadedLatencyMaxPoints: 20
    // number of data points to keep for loaded latency
  };
  var internalConfig = {
    // AIM
    aimMeasurementScoring: {
      packetLoss: threshold([0.01, 0.05, 0.25, 0.5], [10, 5, 0, -10, -20]),
      latency: threshold([10, 20, 50, 100, 500], [20, 10, 5, 0, -10, -20]),
      loadedLatencyIncrease: threshold([10, 20, 50, 100, 500], [20, 10, 5, 0, -10, -20]),
      jitter: threshold([10, 20, 100, 500], [10, 5, 0, -10, -20]),
      download: threshold([1e6, 1e7, 5e7, 1e8], [0, 5, 10, 20, 30]),
      upload: threshold([1e6, 1e7, 5e7, 1e8], [0, 5, 10, 20, 30])
    },
    aimExperiencesDefs: {
      streaming: {
        input: ["latency", "packetLoss", "download", "loadedLatencyIncrease"],
        pointThresholds: [15, 20, 40, 60]
      },
      gaming: {
        input: ["latency", "packetLoss", "loadedLatencyIncrease"],
        pointThresholds: [5, 15, 25, 30]
      },
      rtc: {
        input: ["latency", "jitter", "packetLoss", "loadedLatencyIncrease"],
        pointThresholds: [5, 15, 25, 40]
      }
    }
  };
  var MAX_RETRIES = 20;
  var ESTIMATED_HEADER_FRACTION = 5e-3;
  var cfGetServerTime = function cfGetServerTime2(r) {
    var serverTiming = r.headers.get("server-timing");
    if (serverTiming) {
      var re = serverTiming.match(/dur=([0-9.]+)/);
      if (re) return +re[1];
    }
  };
  var getTtfb = function getTtfb2(perf) {
    return perf.responseStart - perf.requestStart;
  };
  var gePayloadDownload = function gePayloadDownload2(perf) {
    return perf.responseEnd - perf.responseStart;
  };
  var calcDownloadDuration = function calcDownloadDuration2(_ref) {
    var ping = _ref.ping, payloadDownloadTime = _ref.payloadDownloadTime;
    return ping + payloadDownloadTime;
  };
  var calcUploadDuration = function calcUploadDuration2(_ref2) {
    var ttfb = _ref2.ttfb;
    return ttfb;
  };
  var calcDownloadSpeed = function calcDownloadSpeed2(_ref3, numBytes) {
    var duration = _ref3.duration, transferSize = _ref3.transferSize;
    var bits = 8 * (transferSize || +numBytes * (1 + ESTIMATED_HEADER_FRACTION));
    var secs = duration / 1e3;
    return !secs ? void 0 : bits / secs;
  };
  var calcUploadSpeed = function calcUploadSpeed2(_ref4, numBytes) {
    var duration = _ref4.duration;
    var bits = 8 * numBytes * (1 + ESTIMATED_HEADER_FRACTION);
    var secs = duration / 1e3;
    return !secs ? void 0 : bits / secs;
  };
  var genContent = (0, import_lodash.default)(function(numBytes) {
    return "0".repeat(numBytes);
  });
  var _qsParams = /* @__PURE__ */ new WeakMap();
  var _fetchOptions = /* @__PURE__ */ new WeakMap();
  var _responseHook = /* @__PURE__ */ new WeakMap();
  var _onRunningChange = /* @__PURE__ */ new WeakMap();
  var _onNewMeasurementStarted = /* @__PURE__ */ new WeakMap();
  var _onMeasurementResult = /* @__PURE__ */ new WeakMap();
  var _onFinished$1 = /* @__PURE__ */ new WeakMap();
  var _onConnectionError$1 = /* @__PURE__ */ new WeakMap();
  var _measurements = /* @__PURE__ */ new WeakMap();
  var _downloadApi = /* @__PURE__ */ new WeakMap();
  var _uploadApi = /* @__PURE__ */ new WeakMap();
  var _running$2 = /* @__PURE__ */ new WeakMap();
  var _finished$1 = /* @__PURE__ */ new WeakMap();
  var _results$1 = /* @__PURE__ */ new WeakMap();
  var _measIdx = /* @__PURE__ */ new WeakMap();
  var _counter = /* @__PURE__ */ new WeakMap();
  var _retries = /* @__PURE__ */ new WeakMap();
  var _minDuration = /* @__PURE__ */ new WeakMap();
  var _throttleMs = /* @__PURE__ */ new WeakMap();
  var _estimatedServerTime = /* @__PURE__ */ new WeakMap();
  var _currentAbortController = /* @__PURE__ */ new WeakMap();
  var _BandwidthMeasurementEngine_brand = /* @__PURE__ */ new WeakSet();
  var BandwidthMeasurementEngine = /* @__PURE__ */ (function() {
    function BandwidthMeasurementEngine2(_measurements2) {
      var _ref5 = arguments.length > 1 && arguments[1] !== void 0 ? arguments[1] : {}, downloadApiUrl = _ref5.downloadApiUrl, uploadApiUrl = _ref5.uploadApiUrl, _ref5$throttleMs = _ref5.throttleMs, throttleMs = _ref5$throttleMs === void 0 ? 0 : _ref5$throttleMs, _ref5$estimatedServer = _ref5.estimatedServerTime, estimatedServerTime = _ref5$estimatedServer === void 0 ? 0 : _ref5$estimatedServer;
      _classCallCheck(this, BandwidthMeasurementEngine2);
      _classPrivateMethodInitSpec(this, _BandwidthMeasurementEngine_brand);
      _classPrivateFieldInitSpec(this, _qsParams, {});
      _classPrivateFieldInitSpec(this, _fetchOptions, {});
      _defineProperty(this, "finishRequestDuration", 1e3);
      _defineProperty(this, "abortRequestDuration", 0);
      _defineProperty(this, "getServerTime", cfGetServerTime);
      _classPrivateFieldInitSpec(this, _responseHook, function(r) {
        return r;
      });
      _classPrivateFieldInitSpec(this, _onRunningChange, function() {
      });
      _classPrivateFieldInitSpec(this, _onNewMeasurementStarted, function() {
      });
      _classPrivateFieldInitSpec(this, _onMeasurementResult, function() {
      });
      _classPrivateFieldInitSpec(this, _onFinished$1, function() {
      });
      _classPrivateFieldInitSpec(this, _onConnectionError$1, function() {
      });
      _classPrivateFieldInitSpec(this, _measurements, void 0);
      _classPrivateFieldInitSpec(this, _downloadApi, void 0);
      _classPrivateFieldInitSpec(this, _uploadApi, void 0);
      _classPrivateFieldInitSpec(this, _running$2, false);
      _classPrivateFieldInitSpec(this, _finished$1, {
        down: false,
        up: false
      });
      _classPrivateFieldInitSpec(this, _results$1, {
        down: {},
        up: {}
      });
      _classPrivateFieldInitSpec(this, _measIdx, 0);
      _classPrivateFieldInitSpec(this, _counter, 0);
      _classPrivateFieldInitSpec(this, _retries, 0);
      _classPrivateFieldInitSpec(this, _minDuration, -Infinity);
      _classPrivateFieldInitSpec(this, _throttleMs, 0);
      _classPrivateFieldInitSpec(this, _estimatedServerTime, 0);
      _classPrivateFieldInitSpec(this, _currentAbortController, void 0);
      if (!_measurements2) throw new Error("Missing measurements argument");
      if (!downloadApiUrl) throw new Error("Missing downloadApiUrl argument");
      if (!uploadApiUrl) throw new Error("Missing uploadApiUrl argument");
      _classPrivateFieldSet2(_measurements, this, _measurements2);
      _classPrivateFieldSet2(_downloadApi, this, downloadApiUrl);
      _classPrivateFieldSet2(_uploadApi, this, uploadApiUrl);
      _classPrivateFieldSet2(_throttleMs, this, throttleMs);
      _classPrivateFieldSet2(_estimatedServerTime, this, Math.max(0, estimatedServerTime));
    }
    return _createClass(BandwidthMeasurementEngine2, [{
      key: "results",
      get: function get() {
        return _classPrivateFieldGet2(_results$1, this);
      }
    }, {
      key: "qsParams",
      get: (
        // additional query string params to include in the requests
        function get() {
          return _classPrivateFieldGet2(_qsParams, this);
        }
      ),
      set: function set2(v) {
        _classPrivateFieldSet2(_qsParams, this, v);
      }
    }, {
      key: "fetchOptions",
      get: (
        // additional options included in the requests
        function get() {
          return _classPrivateFieldGet2(_fetchOptions, this);
        }
      ),
      set: function set2(v) {
        _classPrivateFieldSet2(_fetchOptions, this, v);
      }
    }, {
      key: "responseHook",
      set: (
        // pipe-through of response objects
        function set2(f) {
          _classPrivateFieldSet2(_responseHook, this, f);
        }
      )
    }, {
      key: "onRunningChange",
      set: (
        // callback invoked when engine starts/stops
        function set2(f) {
          _classPrivateFieldSet2(_onRunningChange, this, f);
        }
      )
    }, {
      key: "onNewMeasurementStarted",
      set: (
        // callback invoked when a new item in the measurement list is started
        function set2(f) {
          _classPrivateFieldSet2(_onNewMeasurementStarted, this, f);
        }
      )
    }, {
      key: "onMeasurementResult",
      set: (
        // callback invoked when a new measurement result arrives
        function set2(f) {
          _classPrivateFieldSet2(_onMeasurementResult, this, f);
        }
      )
    }, {
      key: "onFinished",
      set: (
        // callback invoked when all the measurements are finished
        function set2(f) {
          _classPrivateFieldSet2(_onFinished$1, this, f);
        }
      )
    }, {
      key: "onConnectionError",
      set: (
        // Invoked when unable to get a response from the API
        function set2(f) {
          _classPrivateFieldSet2(_onConnectionError$1, this, f);
        }
      )
      // Public methods
    }, {
      key: "pause",
      value: function pause() {
        _assertClassBrand(_BandwidthMeasurementEngine_brand, this, _cancelCurrentMeasurement).call(this, "pause()");
        _assertClassBrand(_BandwidthMeasurementEngine_brand, this, _setRunning$2).call(this, false);
      }
    }, {
      key: "play",
      value: function play() {
        if (!_classPrivateFieldGet2(_running$2, this)) {
          _assertClassBrand(_BandwidthMeasurementEngine_brand, this, _setRunning$2).call(this, true);
          _assertClassBrand(_BandwidthMeasurementEngine_brand, this, _nextMeasurement).call(this);
        }
      }
    }]);
  })();
  function _setRunning$2(running) {
    var _this = this;
    if (running !== _classPrivateFieldGet2(_running$2, this)) {
      _classPrivateFieldSet2(_running$2, this, running);
      setTimeout(function() {
        return _classPrivateFieldGet2(_onRunningChange, _this).call(_this, _classPrivateFieldGet2(_running$2, _this));
      });
    }
    if (!running) {
      var _classPrivateFieldGet2$1;
      (_classPrivateFieldGet2$1 = _classPrivateFieldGet2(_currentAbortController, this)) === null || _classPrivateFieldGet2$1 === void 0 || _classPrivateFieldGet2$1.abort("setRunning(false)");
    }
  }
  function _saveMeasurementResults(measIdx, measTiming) {
    var _this2 = this;
    var _classPrivateFieldGet3 = _classPrivateFieldGet2(_measurements, this)[measIdx], bytes = _classPrivateFieldGet3.bytes, dir = _classPrivateFieldGet3.dir;
    var results = _classPrivateFieldGet2(_results$1, this);
    var bytesResult = results[dir].hasOwnProperty(bytes) ? results[dir][bytes] : {
      timings: [],
      // count all measurements with same bytes and direction
      numMeasurements: _classPrivateFieldGet2(_measurements, this).filter(function(_ref6) {
        var b = _ref6.bytes, d = _ref6.dir;
        return bytes === b && dir === d;
      }).map(function(m) {
        return m.count;
      }).reduce(function(agg, cnt) {
        return agg + cnt;
      }, 0)
    };
    !!measTiming && bytesResult.timings.push(measTiming);
    bytesResult.timings = bytesResult.timings.slice(-bytesResult.numMeasurements);
    results[dir][bytes] = bytesResult;
    if (measTiming) {
      setTimeout(function() {
        _classPrivateFieldGet2(_onMeasurementResult, _this2).call(_this2, _objectSpread2({
          type: dir,
          bytes
        }, measTiming), results);
      });
    } else {
      _classPrivateFieldGet2(_onNewMeasurementStarted, this).call(this, _classPrivateFieldGet2(_measurements, this)[measIdx], results);
    }
  }
  function _nextMeasurement() {
    var _this3 = this;
    var measurements = _classPrivateFieldGet2(_measurements, this);
    var meas = measurements[_classPrivateFieldGet2(_measIdx, this)];
    if (_classPrivateFieldGet2(_counter, this) >= meas.count) {
      var finished = _classPrivateFieldGet2(_finished$1, this);
      if (_classPrivateFieldGet2(_minDuration, this) > this.finishRequestDuration && !meas.bypassMinDuration) {
        var _dir = meas.dir;
        _classPrivateFieldGet2(_finished$1, this)[_dir] = true;
        Object.values(_classPrivateFieldGet2(_finished$1, this)).every(function(finished2) {
          return finished2;
        }) && _classPrivateFieldGet2(_onFinished$1, this).call(this, _classPrivateFieldGet2(_results$1, this));
      }
      _classPrivateFieldSet2(_counter, this, 0);
      _classPrivateFieldSet2(_minDuration, this, -Infinity);
      performance.clearResourceTimings();
      do {
        _classPrivateFieldSet2(_measIdx, this, _classPrivateFieldGet2(_measIdx, this) + 1);
      } while (_classPrivateFieldGet2(_measIdx, this) < measurements.length && finished[measurements[_classPrivateFieldGet2(_measIdx, this)].dir]);
      if (_classPrivateFieldGet2(_measIdx, this) >= measurements.length) {
        _classPrivateFieldSet2(_finished$1, this, {
          down: true,
          up: true
        });
        _assertClassBrand(_BandwidthMeasurementEngine_brand, this, _setRunning$2).call(this, false);
        _classPrivateFieldGet2(_onFinished$1, this).call(this, _classPrivateFieldGet2(_results$1, this));
        return;
      }
      meas = measurements[_classPrivateFieldGet2(_measIdx, this)];
    }
    var measIdx = _classPrivateFieldGet2(_measIdx, this);
    if (_classPrivateFieldGet2(_counter, this) === 0) {
      _assertClassBrand(_BandwidthMeasurementEngine_brand, this, _saveMeasurementResults).call(this, measIdx);
    }
    var _meas = meas, numBytes = _meas.bytes, dir = _meas.dir;
    var isDown = dir === "down";
    var apiUrl = isDown ? _classPrivateFieldGet2(_downloadApi, this) : _classPrivateFieldGet2(_uploadApi, this);
    var qsParams = Object.assign({}, _classPrivateFieldGet2(_qsParams, this));
    isDown && (qsParams.bytes = "".concat(numBytes));
    var url = "".concat(
      apiUrl.startsWith("http") || apiUrl.startsWith("//") ? "" : window.location.origin
      // use abs to match perf timing urls
    ).concat(apiUrl, "?").concat(Object.entries(qsParams).map(function(_ref7) {
      var _ref8 = _slicedToArray(_ref7, 2), k = _ref8[0], v = _ref8[1];
      return "".concat(k, "=").concat(v);
    }).join("&"));
    var fetchOpt = Object.assign({}, isDown ? {} : {
      method: "POST",
      body: genContent(numBytes)
    }, _classPrivateFieldGet2(_fetchOptions, this));
    if (_classPrivateFieldGet2(_retries, this) === 0) {
      var _classPrivateFieldGet4;
      (_classPrivateFieldGet4 = _classPrivateFieldGet2(_currentAbortController, this)) === null || _classPrivateFieldGet4 === void 0 || _classPrivateFieldGet4.abort("restarting engine");
      _classPrivateFieldSet2(_currentAbortController, this, new AbortController());
      if (this.abortRequestDuration) {
        var abortTimeout = setTimeout(function() {
          var errorMessage = "".concat(isDown ? "Download" : "Upload", " measurement of ").concat(numBytes, " bytes aborted. Measurement exceeded bandwidthAbortRequestDuration (").concat(_this3.abortRequestDuration, "ms)");
          _assertClassBrand(_BandwidthMeasurementEngine_brand, _this3, _cancelCurrentMeasurement).call(_this3, errorMessage);
          _classPrivateFieldSet2(_retries, _this3, 0);
          _assertClassBrand(_BandwidthMeasurementEngine_brand, _this3, _setRunning$2).call(_this3, false);
          _classPrivateFieldGet2(_onConnectionError$1, _this3).call(_this3, errorMessage);
        }, this.abortRequestDuration);
        _classPrivateFieldGet2(_currentAbortController, this).signal.addEventListener("abort", function() {
          return clearTimeout(abortTimeout);
        });
      }
    }
    var serverTime;
    fetch(url, _objectSpread2(_objectSpread2({}, fetchOpt), {}, {
      signal: _classPrivateFieldGet2(_currentAbortController, this).signal
    })).then(function(r) {
      if (r.ok) return r;
      throw Error(r.statusText);
    }).then(function(r) {
      _this3.getServerTime && (serverTime = _this3.getServerTime(r));
      return r;
    }).then(function(r) {
      return r.text().then(function(body) {
        _classPrivateFieldGet2(_responseHook, _this3) && _classPrivateFieldGet2(_responseHook, _this3).call(_this3, {
          url,
          headers: r.headers,
          body
        });
        return body;
      });
    }).then(function() {
      var perf = performance.getEntriesByName(url).slice(-1)[0];
      var timing = {
        transferSize: perf.transferSize,
        ttfb: getTtfb(perf),
        payloadDownloadTime: gePayloadDownload(perf),
        serverTime: serverTime || -1,
        measTime: /* @__PURE__ */ new Date()
      };
      timing.ping = Math.max(0.01, timing.ttfb - (serverTime || _classPrivateFieldGet2(_estimatedServerTime, _this3)));
      timing.duration = (isDown ? calcDownloadDuration : calcUploadDuration)(timing);
      timing.bps = (isDown ? calcDownloadSpeed : calcUploadSpeed)(timing, numBytes);
      if (isDown && numBytes) {
        var reqSize = +numBytes;
        if (timing.transferSize && (timing.transferSize < reqSize || timing.transferSize / reqSize > 1.05)) {
          console.warn("Requested ".concat(reqSize, "B but received ").concat(timing.transferSize, "B (").concat(Math.round(timing.transferSize / reqSize * 1e4) / 100, "%)."));
        }
      }
      _assertClassBrand(_BandwidthMeasurementEngine_brand, _this3, _saveMeasurementResults).call(_this3, measIdx, timing);
      var requestDuration = timing.duration;
      _classPrivateFieldSet2(_minDuration, _this3, _classPrivateFieldGet2(_minDuration, _this3) < 0 ? requestDuration : Math.min(_classPrivateFieldGet2(_minDuration, _this3), requestDuration));
      _classPrivateFieldSet2(_counter, _this3, _classPrivateFieldGet2(_counter, _this3) + 1);
      _classPrivateFieldSet2(_retries, _this3, 0);
      if (_classPrivateFieldGet2(_throttleMs, _this3)) {
        var throttleTimeout = setTimeout(function() {
          return _assertClassBrand(_BandwidthMeasurementEngine_brand, _this3, _nextMeasurement).call(_this3);
        }, _classPrivateFieldGet2(_throttleMs, _this3));
        _classPrivateFieldGet2(_currentAbortController, _this3).signal.addEventListener("abort", function() {
          return clearTimeout(throttleTimeout);
        });
      } else {
        _assertClassBrand(_BandwidthMeasurementEngine_brand, _this3, _nextMeasurement).call(_this3);
      }
    })["catch"](function(error) {
      var _this$retries, _this$retries2;
      if (_classPrivateFieldGet2(_currentAbortController, _this3).signal.aborted) {
        return;
      }
      console.warn("Error fetching ".concat(url, ": ").concat(error));
      if ((_classPrivateFieldSet2(_retries, _this3, (_this$retries = _classPrivateFieldGet2(_retries, _this3), _this$retries2 = _this$retries++, _this$retries)), _this$retries2) < MAX_RETRIES) {
        _assertClassBrand(_BandwidthMeasurementEngine_brand, _this3, _nextMeasurement).call(_this3);
      } else {
        _classPrivateFieldSet2(_retries, _this3, 0);
        _assertClassBrand(_BandwidthMeasurementEngine_brand, _this3, _setRunning$2).call(_this3, false);
        _classPrivateFieldGet2(_onConnectionError$1, _this3).call(_this3, "Connection failed to ".concat(url, ". Gave up after ").concat(MAX_RETRIES, " retries."));
      }
    });
  }
  function _cancelCurrentMeasurement(reason) {
    var _classPrivateFieldGet5;
    (_classPrivateFieldGet5 = _classPrivateFieldGet2(_currentAbortController, this)) === null || _classPrivateFieldGet5 === void 0 || _classPrivateFieldGet5.abort(reason || "aborted with no reason provided");
  }
  var _excluded$5 = ["measureParallelLatency", "parallelLatencyThrottleMs", "downloadApiUrl", "uploadApiUrl", "estimatedServerTime"];
  var _latencyEngine = /* @__PURE__ */ new WeakMap();
  var _latencyTimeout = /* @__PURE__ */ new WeakMap();
  var _BandwidthWithParallelLatencyEngine_brand = /* @__PURE__ */ new WeakSet();
  var BandwidthWithParallelLatencyEngine = /* @__PURE__ */ (function(_BandwidthEngine) {
    function BandwidthWithParallelLatencyEngine2(measurements) {
      var _this;
      var _ref = arguments.length > 1 && arguments[1] !== void 0 ? arguments[1] : {}, _ref$measureParallelL = _ref.measureParallelLatency, measureParallelLatency = _ref$measureParallelL === void 0 ? false : _ref$measureParallelL, _ref$parallelLatencyT = _ref.parallelLatencyThrottleMs, parallelLatencyThrottleMs = _ref$parallelLatencyT === void 0 ? 100 : _ref$parallelLatencyT, downloadApiUrl = _ref.downloadApiUrl, uploadApiUrl = _ref.uploadApiUrl, _ref$estimatedServerT = _ref.estimatedServerTime, estimatedServerTime = _ref$estimatedServerT === void 0 ? 0 : _ref$estimatedServerT, ptProps = _objectWithoutProperties(_ref, _excluded$5);
      _classCallCheck(this, BandwidthWithParallelLatencyEngine2);
      _this = _callSuper(this, BandwidthWithParallelLatencyEngine2, [measurements, _objectSpread2({
        downloadApiUrl,
        uploadApiUrl,
        estimatedServerTime
      }, ptProps)]);
      _classPrivateMethodInitSpec(_this, _BandwidthWithParallelLatencyEngine_brand);
      _classPrivateFieldInitSpec(_this, _latencyEngine, void 0);
      _classPrivateFieldInitSpec(_this, _latencyTimeout, void 0);
      if (measureParallelLatency) {
        _classPrivateFieldSet2(_latencyEngine, _this, new BandwidthMeasurementEngine([{
          dir: "down",
          bytes: 0,
          count: Infinity,
          bypassMinDuration: true
        }], {
          downloadApiUrl,
          uploadApiUrl,
          estimatedServerTime,
          throttleMs: parallelLatencyThrottleMs
        }));
        _classPrivateFieldGet2(_latencyEngine, _this).qsParams = {
          during: "".concat(measurements[0].dir, "load")
        };
        _superPropSet(BandwidthWithParallelLatencyEngine2, "onRunningChange", _assertClassBrand(_BandwidthWithParallelLatencyEngine_brand, _this, _setLatencyRunning), _this, 1);
        _superPropSet(BandwidthWithParallelLatencyEngine2, "onConnectionError", function() {
          return _classPrivateFieldGet2(_latencyEngine, _this).pause();
        }, _this, 1);
      }
      return _this;
    }
    _inherits(BandwidthWithParallelLatencyEngine2, _BandwidthEngine);
    return _createClass(BandwidthWithParallelLatencyEngine2, [{
      key: "latencyResults",
      get: function get() {
        return _classPrivateFieldGet2(_latencyEngine, this) && _classPrivateFieldGet2(_latencyEngine, this).results.down[0].timings;
      }
      // callback invoked when a new parallel latency result arrives
    }, {
      key: "onParallelLatencyResult",
      set: function set2(f) {
        _classPrivateFieldGet2(_latencyEngine, this) && (_classPrivateFieldGet2(_latencyEngine, this).onMeasurementResult = function(res) {
          return f(res);
        });
      }
      // Overridden attributes
    }, {
      key: "fetchOptions",
      get: function get() {
        return _superPropGet(BandwidthWithParallelLatencyEngine2, "fetchOptions", this, 1);
      },
      set: function set2(fetchOptions) {
        _superPropSet(BandwidthWithParallelLatencyEngine2, "fetchOptions", fetchOptions, this, 1);
        _classPrivateFieldGet2(_latencyEngine, this) && (_classPrivateFieldGet2(_latencyEngine, this).fetchOptions = fetchOptions);
      }
    }, {
      key: "onRunningChange",
      set: function set2(onRunningChange) {
        var _this2 = this;
        _superPropSet(BandwidthWithParallelLatencyEngine2, "onRunningChange", function(running) {
          _assertClassBrand(_BandwidthWithParallelLatencyEngine_brand, _this2, _setLatencyRunning).call(_this2, running);
          onRunningChange(running);
        }, this, 1);
      }
    }, {
      key: "onConnectionError",
      set: function set2(onConnectionError) {
        var _this3 = this;
        _superPropSet(BandwidthWithParallelLatencyEngine2, "onConnectionError", function() {
          _classPrivateFieldGet2(_latencyEngine, _this3) && _classPrivateFieldGet2(_latencyEngine, _this3).pause();
          onConnectionError.apply(void 0, arguments);
        }, this, 1);
      }
    }]);
  })(BandwidthMeasurementEngine);
  function _setLatencyRunning(running) {
    var _this4 = this;
    if (_classPrivateFieldGet2(_latencyEngine, this)) {
      if (!running) {
        clearTimeout(_classPrivateFieldGet2(_latencyTimeout, this));
        _classPrivateFieldGet2(_latencyEngine, this).pause();
      } else {
        _classPrivateFieldSet2(_latencyTimeout, this, setTimeout(function() {
          return _classPrivateFieldGet2(_latencyEngine, _this4).play();
        }, 20));
      }
    }
  }
  var _excluded$4 = ["measurementId", "logApiUrl", "sessionId"];
  var _measurementId$1 = /* @__PURE__ */ new WeakMap();
  var _token = /* @__PURE__ */ new WeakMap();
  var _requestTime = /* @__PURE__ */ new WeakMap();
  var _logApiUrl = /* @__PURE__ */ new WeakMap();
  var _sessionId$1 = /* @__PURE__ */ new WeakMap();
  var _LoggingBandwidthEngine_brand = /* @__PURE__ */ new WeakSet();
  var LoggingBandwidthEngine = /* @__PURE__ */ (function(_BandwidthEngine) {
    function LoggingBandwidthEngine2(measurements) {
      var _this;
      var _ref = arguments.length > 1 && arguments[1] !== void 0 ? arguments[1] : {}, measurementId = _ref.measurementId, logApiUrl = _ref.logApiUrl, sessionId = _ref.sessionId, ptProps = _objectWithoutProperties(_ref, _excluded$4);
      _classCallCheck(this, LoggingBandwidthEngine2);
      _this = _callSuper(this, LoggingBandwidthEngine2, [measurements, ptProps]);
      _classPrivateMethodInitSpec(_this, _LoggingBandwidthEngine_brand);
      _classPrivateFieldInitSpec(_this, _measurementId$1, void 0);
      _classPrivateFieldInitSpec(_this, _token, void 0);
      _classPrivateFieldInitSpec(_this, _requestTime, void 0);
      _classPrivateFieldInitSpec(_this, _logApiUrl, void 0);
      _classPrivateFieldInitSpec(_this, _sessionId$1, void 0);
      _classPrivateFieldSet2(_measurementId$1, _this, measurementId);
      _classPrivateFieldSet2(_logApiUrl, _this, logApiUrl);
      _classPrivateFieldSet2(_sessionId$1, _this, sessionId);
      _superPropSet(LoggingBandwidthEngine2, "qsParams", logApiUrl ? {
        measId: _classPrivateFieldGet2(_measurementId$1, _this)
      } : {}, _this, 1);
      _superPropSet(LoggingBandwidthEngine2, "responseHook", function(r) {
        return _assertClassBrand(_LoggingBandwidthEngine_brand, _this, _loggingResponseHook).call(_this, r);
      }, _this, 1);
      _superPropSet(LoggingBandwidthEngine2, "onMeasurementResult", function(meas) {
        return _assertClassBrand(_LoggingBandwidthEngine_brand, _this, _logMeasurement).call(_this, meas);
      }, _this, 1);
      return _this;
    }
    _inherits(LoggingBandwidthEngine2, _BandwidthEngine);
    return _createClass(LoggingBandwidthEngine2, [{
      key: "qsParams",
      set: function set2(qsParams) {
        _superPropSet(LoggingBandwidthEngine2, "qsParams", _classPrivateFieldGet2(_logApiUrl, this) ? _objectSpread2({
          measId: _classPrivateFieldGet2(_measurementId$1, this)
        }, qsParams) : qsParams, this, 1);
      }
    }, {
      key: "responseHook",
      set: function set2(responseHook) {
        var _this2 = this;
        _superPropSet(LoggingBandwidthEngine2, "responseHook", function(r) {
          responseHook(r);
          _assertClassBrand(_LoggingBandwidthEngine_brand, _this2, _loggingResponseHook).call(_this2, r);
        }, this, 1);
      }
    }, {
      key: "onMeasurementResult",
      set: function set2(onMeasurementResult) {
        var _this3 = this;
        _superPropSet(LoggingBandwidthEngine2, "onMeasurementResult", function(meas) {
          for (var _len = arguments.length, restArgs = new Array(_len > 1 ? _len - 1 : 0), _key = 1; _key < _len; _key++) {
            restArgs[_key - 1] = arguments[_key];
          }
          onMeasurementResult.apply(void 0, [meas].concat(restArgs));
          _assertClassBrand(_LoggingBandwidthEngine_brand, _this3, _logMeasurement).call(_this3, meas);
        }, this, 1);
      }
    }]);
  })(BandwidthWithParallelLatencyEngine);
  function _loggingResponseHook(r) {
    if (!_classPrivateFieldGet2(_logApiUrl, this)) return;
    _classPrivateFieldSet2(_requestTime, this, +r.headers.get("cf-meta-request-time"));
    _classPrivateFieldSet2(_token, this, r.body.slice(-300).split("___").pop());
  }
  function _logMeasurement(measData) {
    if (!_classPrivateFieldGet2(_logApiUrl, this)) return;
    var logData = {
      type: measData.type,
      bytes: measData.bytes,
      ping: Math.round(measData.ping),
      // round to ms
      ttfb: Math.round(measData.ttfb),
      // round to ms
      payloadDownloadTime: Math.round(measData.payloadDownloadTime),
      duration: Math.round(measData.duration),
      transferSize: Math.round(measData.transferSize),
      serverTime: Math.round(measData.serverTime),
      token: _classPrivateFieldGet2(_token, this),
      requestTime: _classPrivateFieldGet2(_requestTime, this),
      measId: _classPrivateFieldGet2(_measurementId$1, this),
      sessionId: _classPrivateFieldGet2(_sessionId$1, this)
    };
    _classPrivateFieldSet2(_token, this, null);
    _classPrivateFieldSet2(_requestTime, this, null);
    fetch(_classPrivateFieldGet2(_logApiUrl, this), _objectSpread2({
      method: "POST",
      body: JSON.stringify(logData)
    }, this.fetchOptions));
  }
  var _running$1 = /* @__PURE__ */ new WeakMap();
  var _currentPromise = /* @__PURE__ */ new WeakMap();
  var _promiseFn = /* @__PURE__ */ new WeakMap();
  var _PromiseEngine_brand = /* @__PURE__ */ new WeakSet();
  var PromiseEngine = /* @__PURE__ */ (function() {
    function PromiseEngine2(promiseFn) {
      _classCallCheck(this, PromiseEngine2);
      _classPrivateMethodInitSpec(this, _PromiseEngine_brand);
      _classPrivateFieldInitSpec(this, _running$1, false);
      _classPrivateFieldInitSpec(this, _currentPromise, void 0);
      _classPrivateFieldInitSpec(this, _promiseFn, void 0);
      if (!promiseFn) throw new Error("Missing operation to perform");
      _classPrivateFieldSet2(_promiseFn, this, promiseFn);
      this.play();
    }
    return _createClass(PromiseEngine2, [{
      key: "pause",
      value: function pause() {
        _assertClassBrand(_PromiseEngine_brand, this, _cancelCurrent).call(this);
        _assertClassBrand(_PromiseEngine_brand, this, _setRunning$1).call(this, false);
      }
    }, {
      key: "stop",
      value: function stop() {
        this.pause();
      }
    }, {
      key: "play",
      value: function play() {
        if (!_classPrivateFieldGet2(_running$1, this)) {
          _assertClassBrand(_PromiseEngine_brand, this, _setRunning$1).call(this, true);
          _assertClassBrand(_PromiseEngine_brand, this, _next$1).call(this);
        }
      }
    }]);
  })();
  function _setRunning$1(running) {
    if (running !== _classPrivateFieldGet2(_running$1, this)) {
      _classPrivateFieldSet2(_running$1, this, running);
    }
  }
  function _next$1() {
    var _this2 = this;
    var curPromise = _classPrivateFieldSet2(_currentPromise, this, _classPrivateFieldGet2(_promiseFn, this).call(this).then(function() {
      !curPromise._cancel && _assertClassBrand(_PromiseEngine_brand, _this2, _next$1).call(_this2);
    }));
  }
  function _cancelCurrent() {
    var curPromise = _classPrivateFieldGet2(_currentPromise, this);
    curPromise && (curPromise._cancel = true);
  }
  var _engines = /* @__PURE__ */ new WeakMap();
  var LoadNetworkEngine = /* @__PURE__ */ (function() {
    function LoadNetworkEngine2() {
      var _this = this;
      var _ref = arguments.length > 0 && arguments[0] !== void 0 ? arguments[0] : {}, download = _ref.download, upload = _ref.upload;
      _classCallCheck(this, LoadNetworkEngine2);
      _defineProperty(this, "qsParams", {});
      _defineProperty(this, "fetchOptions", {});
      _classPrivateFieldInitSpec(this, _engines, []);
      if (!download && !upload) throw new Error("Missing at least one of download/upload config");
      [[download, "download"], [upload, "upload"]].filter(function(_ref2) {
        var _ref3 = _slicedToArray(_ref2, 1), cfg = _ref3[0];
        return cfg;
      }).forEach(function(_ref4) {
        var _ref5 = _slicedToArray(_ref4, 2), cfg = _ref5[0], type = _ref5[1];
        var apiUrl = cfg.apiUrl, chunkSize = cfg.chunkSize;
        if (!apiUrl) throw new Error("Missing ".concat(type, " apiUrl argument"));
        if (!chunkSize) throw new Error("Missing ".concat(type, " chunkSize argument"));
      });
      var getLoadEngine = function getLoadEngine2(_ref6) {
        var apiUrl = _ref6.apiUrl, _ref6$qsParams = _ref6.qsParams, qsParams = _ref6$qsParams === void 0 ? {} : _ref6$qsParams, _ref6$fetchOptions = _ref6.fetchOptions, fetchOptions = _ref6$fetchOptions === void 0 ? {} : _ref6$fetchOptions;
        return new PromiseEngine(function() {
          var fetchQsParams = Object.assign({}, qsParams, _this.qsParams);
          var url = "".concat(
            apiUrl.startsWith("http") || apiUrl.startsWith("//") ? "" : window.location.origin
            // use abs to match perf timing urls
          ).concat(apiUrl, "?").concat(Object.entries(fetchQsParams).map(function(_ref7) {
            var _ref8 = _slicedToArray(_ref7, 2), k = _ref8[0], v = _ref8[1];
            return "".concat(k, "=").concat(v);
          }).join("&"));
          var fetchOpt = Object.assign({}, fetchOptions, _this.fetchOptions);
          return fetch(url, fetchOpt).then(function(r) {
            if (r.ok) return r;
            throw Error(r.statusText);
          }).then(function(r) {
            return r.text();
          });
        });
      };
      download && _classPrivateFieldGet2(_engines, this).push(getLoadEngine({
        apiUrl: download.apiUrl,
        qsParams: {
          bytes: "".concat(download.chunkSize)
        }
      }));
      upload && _classPrivateFieldGet2(_engines, this).push(getLoadEngine({
        apiUrl: upload.apiUrl,
        fetchOptions: {
          method: "POST",
          body: "0".repeat(upload.chunkSize)
        }
      }));
    }
    return _createClass(LoadNetworkEngine2, [{
      key: "pause",
      value: (
        // additional options included in the requests
        // Public methods
        function pause() {
          _classPrivateFieldGet2(_engines, this).forEach(function(engine) {
            return engine.pause();
          });
        }
      )
    }, {
      key: "stop",
      value: function stop() {
        this.pause();
      }
    }, {
      key: "play",
      value: function play() {
        _classPrivateFieldGet2(_engines, this).forEach(function(engine) {
          return engine.play();
        });
      }
    }]);
  })();
  var _excluded$3 = ["iceServers", "acceptIceCandidate", "dataChannelCfg"];
  var _established = /* @__PURE__ */ new WeakMap();
  var _sender = /* @__PURE__ */ new WeakMap();
  var _receiver = /* @__PURE__ */ new WeakMap();
  var _senderDc = /* @__PURE__ */ new WeakMap();
  var _receiverDc = /* @__PURE__ */ new WeakMap();
  var SelfWebRtcDataConnection = /* @__PURE__ */ (function() {
    function SelfWebRtcDataConnection2() {
      var _this = this;
      var _ref = arguments.length > 0 && arguments[0] !== void 0 ? arguments[0] : {}, _ref$iceServers = _ref.iceServers, iceServers = _ref$iceServers === void 0 ? [] : _ref$iceServers, _ref$acceptIceCandida = _ref.acceptIceCandidate, acceptIceCandidate = _ref$acceptIceCandida === void 0 ? function(candidate) {
        var protocol = candidate.protocol || "";
        if (!protocol && candidate.candidate) {
          var sdpAttrs = candidate.candidate.split(" ");
          sdpAttrs.length >= 3 && (protocol = sdpAttrs[2]);
        }
        return protocol.toLowerCase() === "udp";
      } : _ref$acceptIceCandida, _ref$dataChannelCfg = _ref.dataChannelCfg, dataChannelCfg = _ref$dataChannelCfg === void 0 ? {
        ordered: false,
        maxRetransmits: 0
      } : _ref$dataChannelCfg, rtcPeerConnectionCfg = _objectWithoutProperties(_ref, _excluded$3);
      _classCallCheck(this, SelfWebRtcDataConnection2);
      _defineProperty(this, "onOpen", function() {
      });
      _defineProperty(this, "onClose", function() {
      });
      _defineProperty(this, "onMessageReceived", function() {
      });
      _classPrivateFieldInitSpec(this, _established, false);
      _classPrivateFieldInitSpec(this, _sender, void 0);
      _classPrivateFieldInitSpec(this, _receiver, void 0);
      _classPrivateFieldInitSpec(this, _senderDc, void 0);
      _classPrivateFieldInitSpec(this, _receiverDc, void 0);
      var sender = new RTCPeerConnection(_objectSpread2({
        iceServers
      }, rtcPeerConnectionCfg));
      var receiver = new RTCPeerConnection(_objectSpread2({
        iceServers
      }, rtcPeerConnectionCfg));
      var senderDc = sender.createDataChannel("channel", dataChannelCfg);
      senderDc.onopen = function() {
        _classPrivateFieldSet2(_established, _this, true);
        _this.onOpen();
      };
      senderDc.onclose = function() {
        return _this.close();
      };
      receiver.ondatachannel = function(e) {
        var dc = e.channel;
        dc.onclose = function() {
          return _this.close();
        };
        dc.onmessage = function(msg) {
          return _this.onMessageReceived(msg.data);
        };
        _classPrivateFieldSet2(_receiverDc, _this, dc);
      };
      sender.onicecandidate = function(e) {
        e.candidate && acceptIceCandidate(e.candidate) && receiver.addIceCandidate(e.candidate);
      };
      receiver.onicecandidate = function(e) {
        e.candidate && acceptIceCandidate(e.candidate) && sender.addIceCandidate(e.candidate);
      };
      sender.createOffer().then(function(offer) {
        return sender.setLocalDescription(offer);
      }).then(function() {
        return receiver.setRemoteDescription(sender.localDescription);
      }).then(function() {
        return receiver.createAnswer();
      }).then(function(answer) {
        return receiver.setLocalDescription(answer);
      }).then(function() {
        return sender.setRemoteDescription(receiver.localDescription);
      });
      _classPrivateFieldSet2(_sender, this, sender);
      _classPrivateFieldSet2(_receiver, this, receiver);
      _classPrivateFieldSet2(_senderDc, this, senderDc);
      _classPrivateFieldSet2(_established, this, false);
    }
    return _createClass(SelfWebRtcDataConnection2, [{
      key: "send",
      value: (
        // callback invoked when a new message is received from the TURN server
        // Public methods
        function send(msg) {
          return _classPrivateFieldGet2(_senderDc, this).send(msg);
        }
      )
    }, {
      key: "close",
      value: function close() {
        _classPrivateFieldGet2(_sender, this) && _classPrivateFieldGet2(_sender, this).close();
        _classPrivateFieldGet2(_receiver, this) && _classPrivateFieldGet2(_receiver, this).close();
        _classPrivateFieldGet2(_senderDc, this) && _classPrivateFieldGet2(_senderDc, this).close();
        _classPrivateFieldGet2(_receiverDc, this) && _classPrivateFieldGet2(_receiverDc, this).close();
        _classPrivateFieldGet2(_established, this) && this.onClose();
        _classPrivateFieldSet2(_established, this, false);
        return this;
      }
    }]);
  })();
  var _onCredentialsFailure = /* @__PURE__ */ new WeakMap();
  var _onConnectionError = /* @__PURE__ */ new WeakMap();
  var _onFinished = /* @__PURE__ */ new WeakMap();
  var _msgTracker = /* @__PURE__ */ new WeakMap();
  var _webRtcConnection = /* @__PURE__ */ new WeakMap();
  var _numMsgs = /* @__PURE__ */ new WeakMap();
  var PacketLossEngine = /* @__PURE__ */ (function() {
    function PacketLossEngine2() {
      var _this = this;
      var _ref = arguments.length > 0 && arguments[0] !== void 0 ? arguments[0] : {}, turnServerUri = _ref.turnServerUri, turnServerCredsApi = _ref.turnServerCredsApi, _ref$turnServerCredsA = _ref.turnServerCredsApiParser, turnServerCredsApiParser = _ref$turnServerCredsA === void 0 ? function(_ref2) {
        var username = _ref2.username, credential = _ref2.credential, server = _ref2.server;
        return {
          turnServerUser: username,
          turnServerPass: credential,
          turnServerUri: server
        };
      } : _ref$turnServerCredsA, _ref$turnServerCredsA2 = _ref.turnServerCredsApiIncludeCredentials, turnServerCredsApiIncludeCredentials = _ref$turnServerCredsA2 === void 0 ? false : _ref$turnServerCredsA2, turnServerUser = _ref.turnServerUser, turnServerPass = _ref.turnServerPass, _ref$numMsgs = _ref.numMsgs, numMsgs = _ref$numMsgs === void 0 ? 100 : _ref$numMsgs, _ref$batchSize = _ref.batchSize, batchSize = _ref$batchSize === void 0 ? 10 : _ref$batchSize, _ref$batchWaitTime = _ref.batchWaitTime, batchWaitTime = _ref$batchWaitTime === void 0 ? 10 : _ref$batchWaitTime, _ref$responsesWaitTim = _ref.responsesWaitTime, responsesWaitTime = _ref$responsesWaitTim === void 0 ? 5e3 : _ref$responsesWaitTim, _ref$connectionTimeou = _ref.connectionTimeout, connectionTimeout = _ref$connectionTimeou === void 0 ? 5e3 : _ref$connectionTimeou;
      _classCallCheck(this, PacketLossEngine2);
      _classPrivateFieldInitSpec(this, _onCredentialsFailure, function() {
      });
      _classPrivateFieldInitSpec(this, _onConnectionError, function() {
      });
      _classPrivateFieldInitSpec(this, _onFinished, function() {
      });
      _defineProperty(this, "onMsgSent", function() {
      });
      _defineProperty(this, "onAllMsgsSent", function() {
      });
      _defineProperty(this, "onMsgReceived", function() {
      });
      _classPrivateFieldInitSpec(this, _msgTracker, {});
      _classPrivateFieldInitSpec(this, _webRtcConnection, void 0);
      _classPrivateFieldInitSpec(this, _numMsgs, void 0);
      if (!turnServerUri && !turnServerCredsApi) throw new Error("Missing turnServerCredsApi or turnServerUri argument");
      if ((!turnServerUser || !turnServerPass) && !turnServerCredsApi) throw new Error("Missing either turnServerCredsApi or turnServerUser+turnServerPass arguments");
      _classPrivateFieldSet2(_numMsgs, this, numMsgs);
      (!turnServerUser || !turnServerPass ? (
        // Get TURN credentials from API endpoint if not statically supplied
        fetch(turnServerCredsApi, {
          credentials: turnServerCredsApiIncludeCredentials ? "include" : void 0
        }).then(function(r) {
          return r.json();
        }).then(function(d) {
          if (d.error) throw d.error;
          return d;
        }).then(turnServerCredsApiParser)
      ) : Promise.resolve({
        turnServerUser,
        turnServerPass
      }))["catch"](function(e) {
        return _classPrivateFieldGet2(_onCredentialsFailure, _this).call(_this, e);
      }).then(function(_ref3) {
        var turnServerUser2 = _ref3.turnServerUser, turnServerPass2 = _ref3.turnServerPass, credsApiTurnServerUri = _ref3.turnServerUri;
        var c = _classPrivateFieldSet2(_webRtcConnection, _this, new SelfWebRtcDataConnection({
          iceServers: [{
            urls: "turn:".concat(credsApiTurnServerUri || turnServerUri, "?transport=udp"),
            username: turnServerUser2,
            credential: turnServerPass2
          }],
          iceTransportPolicy: "relay"
        }));
        var connectionSuccess = false;
        setTimeout(function() {
          if (!connectionSuccess) {
            c.close();
            _classPrivateFieldGet2(_onConnectionError, _this).call(_this, "ICE connection timeout!");
          }
        }, connectionTimeout);
        var msgTracker = _classPrivateFieldGet2(_msgTracker, _this);
        c.onOpen = function() {
          connectionSuccess = true;
          var self2 = _this;
          (function sendNum(n) {
            if (n <= numMsgs) {
              var i = n;
              while (i <= Math.min(numMsgs, n + batchSize - 1)) {
                msgTracker[i] = false;
                c.send(i);
                self2.onMsgSent(i);
                i++;
              }
              setTimeout(function() {
                return sendNum(i);
              }, batchWaitTime);
            } else {
              self2.onAllMsgsSent(Object.keys(msgTracker).length);
              var finishFn = function finishFn2() {
                c.close();
                _classPrivateFieldGet2(_onFinished, self2).call(self2, self2.results);
              };
              var finishTimeout = setTimeout(finishFn, responsesWaitTime);
              var missingMsgs = Object.values(_classPrivateFieldGet2(_msgTracker, self2)).filter(function(recv) {
                return !recv;
              }).length;
              c.onMessageReceived = function(msg) {
                clearTimeout(finishTimeout);
                msgTracker[msg] = true;
                self2.onMsgReceived(msg);
                missingMsgs--;
                if (missingMsgs <= 0 && Object.values(_classPrivateFieldGet2(_msgTracker, self2)).every(function(recv) {
                  return recv;
                })) {
                  finishFn();
                } else {
                  finishTimeout = setTimeout(finishFn, responsesWaitTime);
                }
              };
            }
          })(1);
        };
        c.onMessageReceived = function(msg) {
          msgTracker[msg] = true;
          _this.onMsgReceived(msg);
        };
      })["catch"](function(e) {
        return _classPrivateFieldGet2(_onConnectionError, _this).call(_this, e.toString());
      });
    }
    return _createClass(PacketLossEngine2, [{
      key: "onCredentialsFailure",
      set: (
        // Invoked when unable to fetch TURN server credentials
        function set2(f) {
          _classPrivateFieldSet2(_onCredentialsFailure, this, f);
        }
      )
    }, {
      key: "onConnectionError",
      set: (
        // Invoked when unable to establish a connection with TURN server
        function set2(f) {
          _classPrivateFieldSet2(_onConnectionError, this, f);
        }
      )
    }, {
      key: "onFinished",
      set: (
        // Invoked when the packet loss measurement is complete
        function set2(f) {
          _classPrivateFieldSet2(_onFinished, this, f);
        }
      )
    }, {
      key: "results",
      get: (
        // Invoked when receiving a new message from the TURN server
        function get() {
          var totalMessages = _classPrivateFieldGet2(_numMsgs, this);
          var numMessagesSent = Object.keys(_classPrivateFieldGet2(_msgTracker, this)).length;
          var lostMessages = Object.entries(_classPrivateFieldGet2(_msgTracker, this)).filter(function(_ref4) {
            var _ref5 = _slicedToArray(_ref4, 2), recv = _ref5[1];
            return !recv;
          }).map(function(_ref6) {
            var _ref7 = _slicedToArray(_ref6, 1), n = _ref7[0];
            return +n;
          });
          var packetLoss = lostMessages.length / numMessagesSent;
          return {
            totalMessages,
            numMessagesSent,
            packetLoss,
            lostMessages
          };
        }
      )
    }]);
  })();
  var _excluded$2 = ["downloadChunkSize", "uploadChunkSize", "downloadApiUrl", "uploadApiUrl"];
  var _loadEngine = /* @__PURE__ */ new WeakMap();
  var PacketLossUnderLoadEngine = /* @__PURE__ */ (function(_PacketLossEngine) {
    function PacketLossUnderLoadEngine2() {
      var _this;
      var _ref = arguments.length > 0 && arguments[0] !== void 0 ? arguments[0] : {}, downloadChunkSize = _ref.downloadChunkSize, uploadChunkSize = _ref.uploadChunkSize, downloadApiUrl = _ref.downloadApiUrl, uploadApiUrl = _ref.uploadApiUrl, ptProps = _objectWithoutProperties(_ref, _excluded$2);
      _classCallCheck(this, PacketLossUnderLoadEngine2);
      _this = _callSuper(this, PacketLossUnderLoadEngine2, [ptProps]);
      _classPrivateFieldInitSpec(_this, _loadEngine, void 0);
      if (downloadChunkSize || uploadChunkSize) {
        _classPrivateFieldSet2(_loadEngine, _this, new LoadNetworkEngine({
          download: downloadChunkSize ? {
            apiUrl: downloadApiUrl,
            chunkSize: downloadChunkSize
          } : null,
          upload: uploadChunkSize ? {
            apiUrl: uploadApiUrl,
            chunkSize: uploadChunkSize
          } : null
        }));
        _superPropSet(PacketLossUnderLoadEngine2, "onCredentialsFailure", _superPropSet(PacketLossUnderLoadEngine2, "onConnectionError", _superPropSet(PacketLossUnderLoadEngine2, "onFinished", function() {
          return _classPrivateFieldGet2(_loadEngine, _this).stop();
        }, _this, 1, 1), _this, 1, 1), _this, 1);
      }
      return _this;
    }
    _inherits(PacketLossUnderLoadEngine2, _PacketLossEngine);
    return _createClass(PacketLossUnderLoadEngine2, [{
      key: "qsParams",
      set: function set2(qsParams) {
        _classPrivateFieldGet2(_loadEngine, this) && (_classPrivateFieldGet2(_loadEngine, this).qsParams = qsParams);
      }
    }, {
      key: "fetchOptions",
      set: function set2(fetchOptions) {
        _classPrivateFieldGet2(_loadEngine, this) && (_classPrivateFieldGet2(_loadEngine, this).fetchOptions = fetchOptions);
      }
    }, {
      key: "onCredentialsFailure",
      set: function set2(onCredentialsFailure) {
        var _this2 = this;
        _superPropSet(PacketLossUnderLoadEngine2, "onCredentialsFailure", function() {
          onCredentialsFailure.apply(void 0, arguments);
          _classPrivateFieldGet2(_loadEngine, _this2) && _classPrivateFieldGet2(_loadEngine, _this2).stop();
        }, this, 1);
      }
    }, {
      key: "onConnectionError",
      set: function set2(onConnectionError) {
        var _this3 = this;
        _superPropSet(PacketLossUnderLoadEngine2, "onConnectionError", function() {
          onConnectionError.apply(void 0, arguments);
          _classPrivateFieldGet2(_loadEngine, _this3) && _classPrivateFieldGet2(_loadEngine, _this3).stop();
        }, this, 1);
      }
    }, {
      key: "onFinished",
      set: function set2(onFinished) {
        var _this4 = this;
        _superPropSet(PacketLossUnderLoadEngine2, "onFinished", function() {
          onFinished.apply(void 0, arguments);
          _classPrivateFieldGet2(_loadEngine, _this4) && _classPrivateFieldGet2(_loadEngine, _this4).stop();
        }, this, 1);
      }
    }]);
  })(PacketLossEngine);
  var _excluded$1 = ["reachable"];
  var ReachabilityEngine = /* @__PURE__ */ _createClass(function ReachabilityEngine2(targetUrl) {
    var _this = this;
    var _ref = arguments.length > 1 && arguments[1] !== void 0 ? arguments[1] : {}, _ref$timeout = _ref.timeout, timeout = _ref$timeout === void 0 ? -1 : _ref$timeout, _ref$fetchOptions = _ref.fetchOptions, fetchOptions = _ref$fetchOptions === void 0 ? {} : _ref$fetchOptions;
    _classCallCheck(this, ReachabilityEngine2);
    _defineProperty(this, "onFinished", function() {
    });
    var finished = false;
    var finish = function finish2(_ref2) {
      var reachable = _ref2.reachable, rest = _objectWithoutProperties(_ref2, _excluded$1);
      if (finished) return;
      finished = true;
      _this.onFinished(_objectSpread2({
        targetUrl,
        reachable
      }, rest));
    };
    fetch(targetUrl, fetchOptions).then(function(response) {
      finish({
        reachable: true,
        response
      });
    })["catch"](function(error) {
      finish({
        reachable: false,
        error
      });
    });
    timeout > 0 && setTimeout(function() {
      return finish({
        reachable: false,
        error: "Request timeout"
      });
    }, timeout);
  });
  var sum = function sum2(vals) {
    return vals.reduce(function(agg, val) {
      return agg + val;
    }, 0);
  };
  var percentile = function percentile2(vals) {
    var perc = arguments.length > 1 && arguments[1] !== void 0 ? arguments[1] : 0.5;
    if (!vals.length) return 0;
    var sortedVals = vals.slice().sort(function(a, b) {
      return a - b;
    });
    var idx = (vals.length - 1) * perc;
    var rem = idx % 1;
    if (rem === 0) return sortedVals[Math.round(idx)];
    var edges = [Math.floor, Math.ceil].map(function(rndFn) {
      return sortedVals[rndFn(idx)];
    });
    return edges[0] + (edges[1] - edges[0]) * rem;
  };
  var _config$3 = /* @__PURE__ */ new WeakMap();
  var _extractLoadedLatencies = /* @__PURE__ */ new WeakMap();
  var MeasurementCalculations = /* @__PURE__ */ (function() {
    function MeasurementCalculations2(config) {
      var _this = this;
      _classCallCheck(this, MeasurementCalculations2);
      _defineProperty(this, "getLatencyPoints", function(latencyResults) {
        return latencyResults.timings.map(function(d) {
          return d.ping;
        });
      });
      _defineProperty(this, "getLatency", function(latencyResults) {
        return percentile(_this.getLatencyPoints(latencyResults), _classPrivateFieldGet2(_config$3, _this).latencyPercentile);
      });
      _defineProperty(this, "getBandwidthPoints", function(bandwidthResults) {
        return Object.entries(bandwidthResults).map(function(_ref) {
          var _ref2 = _slicedToArray(_ref, 2), bytes = _ref2[0], timings = _ref2[1].timings;
          return timings.map(function(_ref3) {
            var bps = _ref3.bps, duration = _ref3.duration, ping = _ref3.ping, measTime = _ref3.measTime, serverTime = _ref3.serverTime, transferSize = _ref3.transferSize;
            return {
              bytes: +bytes,
              bps,
              duration,
              ping,
              measTime,
              serverTime,
              transferSize
            };
          });
        }).flat();
      });
      _defineProperty(this, "getBandwidth", function(bandwidthResults) {
        return percentile(_this.getBandwidthPoints(bandwidthResults).filter(function(d) {
          return d.duration >= _classPrivateFieldGet2(_config$3, _this).bandwidthMinRequestDuration;
        }).map(function(d) {
          return d.bps;
        }).filter(function(bps) {
          return bps;
        }), _classPrivateFieldGet2(_config$3, _this).bandwidthPercentile);
      });
      _defineProperty(this, "getLoadedLatency", function(loadedResults) {
        return _this.getLatency({
          timings: _classPrivateFieldGet2(_extractLoadedLatencies, _this).call(_this, loadedResults)
        });
      });
      _defineProperty(this, "getLoadedJitter", function(loadedResults) {
        return _this.getJitter({
          timings: _classPrivateFieldGet2(_extractLoadedLatencies, _this).call(_this, loadedResults)
        });
      });
      _defineProperty(this, "getLoadedLatencyPoints", function(loadedResults) {
        return _this.getLatencyPoints({
          timings: _classPrivateFieldGet2(_extractLoadedLatencies, _this).call(_this, loadedResults)
        });
      });
      _defineProperty(this, "getPacketLoss", function(plResults) {
        return plResults.packetLoss;
      });
      _defineProperty(this, "getPacketLossDetails", function(plResults) {
        return plResults;
      });
      _defineProperty(this, "getReachability", function(reachabilityResults) {
        return !!reachabilityResults.reachable;
      });
      _defineProperty(this, "getReachabilityDetails", function(d) {
        return {
          host: d.host,
          reachable: d.reachable
        };
      });
      _classPrivateFieldInitSpec(this, _config$3, void 0);
      _classPrivateFieldInitSpec(this, _extractLoadedLatencies, function(loadedResults) {
        return Object.values(loadedResults).filter(
          // keep only file sizes that saturated the connection
          function(d) {
            return d.timings.length && Math.min.apply(Math, _toConsumableArray(d.timings.map(function(d2) {
              return d2.duration;
            }))) >= _classPrivateFieldGet2(_config$3, _this).loadedRequestMinDuration;
          }
        ).map(function(d) {
          return d.sideLatency || [];
        }).flat().slice(-_classPrivateFieldGet2(_config$3, _this).loadedLatencyMaxPoints);
      });
      _classPrivateFieldSet2(_config$3, this, config);
    }
    return _createClass(MeasurementCalculations2, [{
      key: "getJitter",
      value: function getJitter(latencyResults) {
        var pings = this.getLatencyPoints(latencyResults);
        return pings.length < 2 ? null : pings.reduce(function(_ref4, latency) {
          var _ref4$sumDeltas = _ref4.sumDeltas, sumDeltas = _ref4$sumDeltas === void 0 ? 0 : _ref4$sumDeltas, prevLatency = _ref4.prevLatency;
          return {
            sumDeltas: sumDeltas + (prevLatency !== void 0 ? Math.abs(prevLatency - latency) : 0),
            prevLatency: latency
          };
        }, {}).sumDeltas / (pings.length - 1);
      }
      // last measurements are most accurate
    }]);
  })();
  var classificationNames = ["bad", "poor", "average", "good", "great"];
  var customResultTypes = {
    loadedLatencyIncrease: function loadedLatencyIncrease(measurements) {
      return measurements.latency && (measurements.downLoadedLatency || measurements.upLoadedLatency) ? Math.max(measurements.downLoadedLatency, measurements.upLoadedLatency) - measurements.latency : void 0;
    }
  };
  var defaultPoints = {
    packetLoss: 0
  };
  var _config$2 = /* @__PURE__ */ new WeakMap();
  var ScoresCalculations = /* @__PURE__ */ (function() {
    function ScoresCalculations2(config) {
      _classCallCheck(this, ScoresCalculations2);
      _classPrivateFieldInitSpec(this, _config$2, void 0);
      _classPrivateFieldSet2(_config$2, this, config);
    }
    return _createClass(ScoresCalculations2, [{
      key: "getScores",
      value: function getScores(measurements) {
        var scores = Object.assign.apply(Object, _toConsumableArray(Object.entries(_classPrivateFieldGet2(_config$2, this).aimMeasurementScoring).map(function(_ref) {
          var _ref2 = _slicedToArray(_ref, 2), type = _ref2[0], fn = _ref2[1];
          var val = customResultTypes.hasOwnProperty(type) ? customResultTypes[type](measurements) : measurements[type];
          return val === void 0 ? defaultPoints.hasOwnProperty(type) ? _defineProperty({}, type, defaultPoints[type]) : {} : _defineProperty({}, type, val === void 0 ? 0 : +fn(val));
        })));
        return Object.assign.apply(Object, [{}].concat(_toConsumableArray(Object.entries(_classPrivateFieldGet2(_config$2, this).aimExperiencesDefs).filter(function(_ref5) {
          var _ref6 = _slicedToArray(_ref5, 2), input = _ref6[1].input;
          return input.every(function(k) {
            return scores.hasOwnProperty(k);
          });
        }).map(function(_ref7) {
          var _ref8 = _slicedToArray(_ref7, 2), k = _ref8[0], _ref8$ = _ref8[1], input = _ref8$.input, pointThresholds = _ref8$.pointThresholds;
          var sumPoints = Math.max(0, sum(input.map(function(k2) {
            return scores[k2];
          })));
          var classificationIdx = threshold(pointThresholds, [0, 1, 2, 3, 4])(sumPoints);
          var classificationName = classificationNames[classificationIdx];
          return _defineProperty({}, k, {
            points: sumPoints,
            classificationIdx,
            classificationName
          });
        }))));
      }
    }]);
  })();
  var _config$1 = /* @__PURE__ */ new WeakMap();
  var _measCalc = /* @__PURE__ */ new WeakMap();
  var _scoresCalc = /* @__PURE__ */ new WeakMap();
  var _calcGetter = /* @__PURE__ */ new WeakMap();
  var _getV4Reachability = /* @__PURE__ */ new WeakMap();
  var _getV4ReachabilityDetails = /* @__PURE__ */ new WeakMap();
  var _getV6Reachability = /* @__PURE__ */ new WeakMap();
  var _getV6ReachabilityDetails = /* @__PURE__ */ new WeakMap();
  var Results = /* @__PURE__ */ (function() {
    function Results2(config) {
      var _this = this;
      _classCallCheck(this, Results2);
      _defineProperty(this, "raw", void 0);
      _defineProperty(this, "getUnloadedLatency", function() {
        return _classPrivateFieldGet2(_calcGetter, _this).call(_this, "getLatency", "latency");
      });
      _defineProperty(this, "getUnloadedJitter", function() {
        return _classPrivateFieldGet2(_calcGetter, _this).call(_this, "getJitter", "latency");
      });
      _defineProperty(this, "getUnloadedLatencyPoints", function() {
        return _classPrivateFieldGet2(_calcGetter, _this).call(_this, "getLatencyPoints", "latency", []);
      });
      _defineProperty(this, "getDownLoadedLatency", function() {
        return _classPrivateFieldGet2(_calcGetter, _this).call(_this, "getLoadedLatency", "download");
      });
      _defineProperty(this, "getDownLoadedJitter", function() {
        return _classPrivateFieldGet2(_calcGetter, _this).call(_this, "getLoadedJitter", "download");
      });
      _defineProperty(this, "getDownLoadedLatencyPoints", function() {
        return _classPrivateFieldGet2(_calcGetter, _this).call(_this, "getLoadedLatencyPoints", "download", []);
      });
      _defineProperty(this, "getUpLoadedLatency", function() {
        return _classPrivateFieldGet2(_calcGetter, _this).call(_this, "getLoadedLatency", "upload");
      });
      _defineProperty(this, "getUpLoadedJitter", function() {
        return _classPrivateFieldGet2(_calcGetter, _this).call(_this, "getLoadedJitter", "upload");
      });
      _defineProperty(this, "getUpLoadedLatencyPoints", function() {
        return _classPrivateFieldGet2(_calcGetter, _this).call(_this, "getLoadedLatencyPoints", "upload", []);
      });
      _defineProperty(this, "getDownloadBandwidth", function() {
        return _classPrivateFieldGet2(_calcGetter, _this).call(_this, "getBandwidth", "download");
      });
      _defineProperty(this, "getDownloadBandwidthPoints", function() {
        return _classPrivateFieldGet2(_calcGetter, _this).call(_this, "getBandwidthPoints", "download", []);
      });
      _defineProperty(this, "getUploadBandwidth", function() {
        return _classPrivateFieldGet2(_calcGetter, _this).call(_this, "getBandwidth", "upload");
      });
      _defineProperty(this, "getUploadBandwidthPoints", function() {
        return _classPrivateFieldGet2(_calcGetter, _this).call(_this, "getBandwidthPoints", "upload", []);
      });
      _defineProperty(this, "getPacketLoss", function() {
        return _classPrivateFieldGet2(_calcGetter, _this).call(_this, "getPacketLoss", "packetLoss");
      });
      _defineProperty(this, "getPacketLossDetails", function() {
        return _classPrivateFieldGet2(_calcGetter, _this).call(_this, "getPacketLossDetails", "packetLoss", void 0, true);
      });
      _defineProperty(this, "getScores", function() {
        return _classPrivateFieldGet2(_scoresCalc, _this).getScores(_this.getSummary());
      });
      _classPrivateFieldInitSpec(this, _config$1, void 0);
      _classPrivateFieldInitSpec(this, _measCalc, void 0);
      _classPrivateFieldInitSpec(this, _scoresCalc, void 0);
      _classPrivateFieldInitSpec(this, _calcGetter, function(calcFn, resKey) {
        var defaultVal = arguments.length > 2 && arguments[2] !== void 0 ? arguments[2] : void 0;
        var surfaceError = arguments.length > 3 && arguments[3] !== void 0 ? arguments[3] : false;
        return !_this.raw.hasOwnProperty(resKey) || !_this.raw[resKey].started ? defaultVal : surfaceError && _this.raw[resKey].error ? {
          error: _this.raw[resKey].error
        } : _classPrivateFieldGet2(_measCalc, _this)[calcFn](_this.raw[resKey].results);
      });
      _classPrivateFieldInitSpec(this, _getV4Reachability, function() {
        return _classPrivateFieldGet2(_calcGetter, _this).call(_this, "getReachability", "v4Reachability");
      });
      _classPrivateFieldInitSpec(this, _getV4ReachabilityDetails, function() {
        return _classPrivateFieldGet2(_calcGetter, _this).call(_this, "getReachabilityDetails", "v4Reachability");
      });
      _classPrivateFieldInitSpec(this, _getV6Reachability, function() {
        return _classPrivateFieldGet2(_calcGetter, _this).call(_this, "getReachability", "v6Reachability");
      });
      _classPrivateFieldInitSpec(this, _getV6ReachabilityDetails, function() {
        return _classPrivateFieldGet2(_calcGetter, _this).call(_this, "getReachabilityDetails", "v6Reachability");
      });
      _classPrivateFieldSet2(_config$1, this, config);
      this.clear();
      _classPrivateFieldSet2(_measCalc, this, new MeasurementCalculations(_classPrivateFieldGet2(_config$1, this)));
      _classPrivateFieldSet2(_scoresCalc, this, new ScoresCalculations(_classPrivateFieldGet2(_config$1, this)));
    }
    return _createClass(Results2, [{
      key: "isFinished",
      get: function get() {
        return Object.values(this.raw).every(function(d) {
          return d.finished;
        });
      }
      // Public methods
    }, {
      key: "clear",
      value: function clear() {
        this.raw = Object.assign.apply(Object, [{}].concat(_toConsumableArray(_toConsumableArray(new Set(_classPrivateFieldGet2(_config$1, this).measurements.map(function(m) {
          return m.type;
        }))).map(function(m) {
          return _defineProperty({}, m, {
            started: false,
            finished: false,
            results: {}
          });
        }))));
      }
    }, {
      key: "getSummary",
      value: function getSummary() {
        var items = {
          download: this.getDownloadBandwidth,
          upload: this.getUploadBandwidth,
          latency: this.getUnloadedLatency,
          jitter: this.getUnloadedJitter,
          downLoadedLatency: this.getDownLoadedLatency,
          downLoadedJitter: this.getDownLoadedJitter,
          upLoadedLatency: this.getUpLoadedLatency,
          upLoadedJitter: this.getUpLoadedJitter,
          packetLoss: this.getPacketLoss,
          v4Reachability: _classPrivateFieldGet2(_getV4Reachability, this),
          v6Reachability: _classPrivateFieldGet2(_getV6Reachability, this)
        };
        return Object.assign.apply(Object, _toConsumableArray(Object.entries(items).map(function(_ref2) {
          var _ref3 = _slicedToArray(_ref2, 2), key = _ref3[0], fn = _ref3[1];
          var val = fn();
          return val === void 0 ? {} : _defineProperty({}, key, val);
        })));
      }
    }]);
  })();
  var round = function round2(num) {
    var decimals = arguments.length > 1 && arguments[1] !== void 0 ? arguments[1] : 0;
    return !num ? num : Math.round(num * Math.pow(10, decimals)) / Math.pow(10, decimals);
  };
  var latencyPointsParser = function latencyPointsParser2(durations) {
    return durations.map(function(d) {
      return round(d, 2);
    });
  };
  var bpsPointsParser = function bpsPointsParser2(pnts) {
    return pnts.map(function(d) {
      return {
        bytes: +d.bytes,
        bps: round(d.bps)
      };
    });
  };
  var packetLossParser = function packetLossParser2(d) {
    return d.error ? void 0 : {
      numMessages: d.numMessagesSent,
      lossRatio: round(d.packetLoss, 4)
    };
  };
  var resultsParsers = {
    latencyMs: ["getUnloadedLatencyPoints", latencyPointsParser],
    download: ["getDownloadBandwidthPoints", bpsPointsParser],
    upload: ["getUploadBandwidthPoints", bpsPointsParser],
    downLoadedLatencyMs: ["getDownLoadedLatencyPoints", latencyPointsParser],
    upLoadedLatencyMs: ["getUpLoadedLatencyPoints", latencyPointsParser],
    packetLoss: ["getPacketLossDetails", packetLossParser]
    // v4Reachability: ['getV4ReachabilityDetails'],
    // v6Reachability: ['getV6ReachabilityDetails']
  };
  var scoreParser = function scoreParser2(d) {
    return {
      points: d.points,
      classification: d.classificationName
    };
  };
  var logAimResults = function logAimResults2(results, _ref) {
    var apiUrl = _ref.apiUrl, sessionId = _ref.sessionId;
    var logData = {
      sessionId
    };
    Object.entries(resultsParsers).forEach(function(_ref2) {
      var _ref3 = _slicedToArray(_ref2, 2), logK = _ref3[0], _ref3$ = _slicedToArray(_ref3[1], 2), fn = _ref3$[0], _ref3$$ = _ref3$[1], parser = _ref3$$ === void 0 ? function(d) {
        return d;
      } : _ref3$$;
      var val = results[fn]();
      val && (logData[logK] = parser(val));
    });
    var scores = results.getScores();
    scores && (logData.scores = Object.assign.apply(Object, [{}].concat(_toConsumableArray(Object.entries(scores).map(function(_ref4) {
      var _ref5 = _slicedToArray(_ref4, 2), k = _ref5[0], score = _ref5[1];
      return _defineProperty({}, k, scoreParser(score));
    })))));
    fetch(apiUrl, {
      method: "POST",
      body: JSON.stringify(logData)
    });
  };
  var _excluded = ["type"];
  var _excluded2 = ["numPackets"];
  var _excluded3 = ["bytes"];
  var DEFAULT_OPTIMAL_DOWNLOAD_SIZE = 1e6;
  var DEFAULT_OPTIMAL_UPLOAD_SIZE = 1e6;
  var OPTIMAL_SIZE_RATIO = 0.5;
  var pausableTypes = ["latency", "latencyUnderLoad", "download", "upload"];
  var genMeasId = function genMeasId2() {
    return "".concat(Math.round(Math.random() * 1e16));
  };
  var _onFinish = /* @__PURE__ */ new WeakMap();
  var _onError = /* @__PURE__ */ new WeakMap();
  var _config = /* @__PURE__ */ new WeakMap();
  var _results = /* @__PURE__ */ new WeakMap();
  var _measurementId = /* @__PURE__ */ new WeakMap();
  var _curMsmIdx = /* @__PURE__ */ new WeakMap();
  var _curEngine = /* @__PURE__ */ new WeakMap();
  var _optimalDownloadChunkSize = /* @__PURE__ */ new WeakMap();
  var _optimalUploadChunkSize = /* @__PURE__ */ new WeakMap();
  var _running = /* @__PURE__ */ new WeakMap();
  var _finished = /* @__PURE__ */ new WeakMap();
  var _MeasurementEngine_brand = /* @__PURE__ */ new WeakSet();
  var MeasurementEngine = /* @__PURE__ */ (function() {
    function MeasurementEngine2() {
      var userConfig = arguments.length > 0 && arguments[0] !== void 0 ? arguments[0] : {};
      _classCallCheck(this, MeasurementEngine2);
      _classPrivateMethodInitSpec(this, _MeasurementEngine_brand);
      _defineProperty(this, "onRunningChange", function() {
      });
      _defineProperty(this, "onResultsChange", function() {
      });
      _defineProperty(this, "onPhaseChange", function() {
      });
      _classPrivateFieldInitSpec(this, _onFinish, function() {
      });
      _classPrivateFieldInitSpec(this, _onError, function() {
      });
      _classPrivateFieldInitSpec(this, _config, void 0);
      _classPrivateFieldInitSpec(this, _results, void 0);
      _classPrivateFieldInitSpec(this, _measurementId, genMeasId());
      _classPrivateFieldInitSpec(this, _curMsmIdx, -1);
      _classPrivateFieldInitSpec(this, _curEngine, void 0);
      _classPrivateFieldInitSpec(this, _optimalDownloadChunkSize, DEFAULT_OPTIMAL_DOWNLOAD_SIZE);
      _classPrivateFieldInitSpec(this, _optimalUploadChunkSize, DEFAULT_OPTIMAL_UPLOAD_SIZE);
      _classPrivateFieldInitSpec(this, _running, false);
      _classPrivateFieldInitSpec(this, _finished, false);
      _classPrivateFieldSet2(_config, this, Object.assign({}, defaultConfig, userConfig, internalConfig));
      _classPrivateFieldSet2(_results, this, new Results(_classPrivateFieldGet2(_config, this)));
      _classPrivateFieldGet2(_config, this).autoStart && this.play();
    }
    return _createClass(MeasurementEngine2, [{
      key: "results",
      get: function get() {
        return _classPrivateFieldGet2(_results, this);
      }
    }, {
      key: "isRunning",
      get: function get() {
        return _classPrivateFieldGet2(_running, this);
      }
    }, {
      key: "isFinished",
      get: function get() {
        return _classPrivateFieldGet2(_finished, this);
      }
    }, {
      key: "onFinish",
      set: (
        // callback invoked when all the measurements are finished
        function set2(f) {
          _classPrivateFieldSet2(_onFinish, this, f);
        }
      )
    }, {
      key: "onError",
      set: (
        // callback invoked if an error occurs during measurement
        function set2(f) {
          _classPrivateFieldSet2(_onError, this, f);
        }
      )
      // Public methods
    }, {
      key: "pause",
      value: function pause() {
        pausableTypes.includes(_assertClassBrand(_MeasurementEngine_brand, this, _curType).call(this)) && _classPrivateFieldGet2(_curEngine, this).pause();
        _assertClassBrand(_MeasurementEngine_brand, this, _setRunning).call(this, false);
      }
    }, {
      key: "play",
      value: function play() {
        if (!_classPrivateFieldGet2(_running, this)) {
          performance.clearResourceTimings();
          performance.setResourceTimingBufferSize(1e4);
          _assertClassBrand(_MeasurementEngine_brand, this, _setRunning).call(this, true);
          _assertClassBrand(_MeasurementEngine_brand, this, _next).call(this);
        }
      }
    }, {
      key: "restart",
      value: function restart() {
        _assertClassBrand(_MeasurementEngine_brand, this, _clear).call(this);
        this.play();
      }
    }]);
  })();
  function _setRunning(running) {
    if (running !== _classPrivateFieldGet2(_running, this)) {
      _classPrivateFieldSet2(_running, this, running);
      this.onRunningChange(_classPrivateFieldGet2(_running, this));
    }
  }
  function _setFinished(finished) {
    var _this3 = this;
    if (finished !== _classPrivateFieldGet2(_finished, this)) {
      _classPrivateFieldSet2(_finished, this, finished);
      finished && setTimeout(function() {
        return _classPrivateFieldGet2(_onFinish, _this3).call(_this3, _this3.results);
      });
    }
  }
  function _curType() {
    return _classPrivateFieldGet2(_curMsmIdx, this) < 0 || _classPrivateFieldGet2(_curMsmIdx, this) >= _classPrivateFieldGet2(_config, this).measurements.length ? null : _classPrivateFieldGet2(_config, this).measurements[_classPrivateFieldGet2(_curMsmIdx, this)].type;
  }
  function _curTypeResults() {
    return _classPrivateFieldGet2(_results, this).raw[_assertClassBrand(_MeasurementEngine_brand, this, _curType).call(this)] || void 0;
  }
  function _clear() {
    _assertClassBrand(_MeasurementEngine_brand, this, _destroyCurEngine).call(this);
    _classPrivateFieldSet2(_measurementId, this, genMeasId());
    _classPrivateFieldSet2(_curMsmIdx, this, -1);
    _classPrivateFieldSet2(_curEngine, this, void 0);
    _assertClassBrand(_MeasurementEngine_brand, this, _setRunning).call(this, false);
    _assertClassBrand(_MeasurementEngine_brand, this, _setFinished).call(this, false);
    _classPrivateFieldGet2(_results, this).clear();
  }
  function _destroyCurEngine() {
    var engine = _classPrivateFieldGet2(_curEngine, this);
    if (!engine) return;
    engine.onFinished = engine.onConnectionError = engine.onFail = engine.onMsgReceived = engine.onCredentialsFailure = engine.onMeasurementResult = function() {
    };
    pausableTypes.includes(_assertClassBrand(_MeasurementEngine_brand, this, _curType).call(this)) && engine.pause();
  }
  function _next() {
    var _this4 = this;
    var _this$curMsmIdx;
    if (pausableTypes.includes(_assertClassBrand(_MeasurementEngine_brand, this, _curType).call(this)) && _assertClassBrand(_MeasurementEngine_brand, this, _curTypeResults).call(this) && _assertClassBrand(_MeasurementEngine_brand, this, _curTypeResults).call(this).started && !_assertClassBrand(_MeasurementEngine_brand, this, _curTypeResults).call(this).finished && !_assertClassBrand(_MeasurementEngine_brand, this, _curTypeResults).call(this).finishedCurrentRound && !_assertClassBrand(_MeasurementEngine_brand, this, _curTypeResults).call(this).error) {
      _classPrivateFieldGet2(_curEngine, this).play();
      return;
    }
    _classPrivateFieldSet2(_curMsmIdx, this, (_this$curMsmIdx = _classPrivateFieldGet2(_curMsmIdx, this), _this$curMsmIdx++, _this$curMsmIdx));
    if (_classPrivateFieldGet2(_curMsmIdx, this) >= _classPrivateFieldGet2(_config, this).measurements.length) {
      _assertClassBrand(_MeasurementEngine_brand, this, _setRunning).call(this, false);
      _assertClassBrand(_MeasurementEngine_brand, this, _setFinished).call(this, true);
      return;
    }
    var _classPrivateFieldGet2$1 = _classPrivateFieldGet2(_config, this).measurements[_classPrivateFieldGet2(_curMsmIdx, this)], type = _classPrivateFieldGet2$1.type, msmConfig = _objectWithoutProperties(_classPrivateFieldGet2$1, _excluded);
    var msmResults = _assertClassBrand(_MeasurementEngine_brand, this, _curTypeResults).call(this);
    this.onPhaseChange({
      measurementId: _classPrivateFieldGet2(_curMsmIdx, this),
      measurement: _objectSpread2({
        type
      }, msmConfig)
    });
    var _classPrivateFieldGet3 = _classPrivateFieldGet2(_config, this), downloadApiUrl = _classPrivateFieldGet3.downloadApiUrl, uploadApiUrl = _classPrivateFieldGet3.uploadApiUrl, estimatedServerTime = _classPrivateFieldGet3.estimatedServerTime;
    var engine;
    switch (type) {
      case "v4Reachability":
      case "v6Reachability":
        engine = new ReachabilityEngine("https://".concat(msmConfig.host), {
          fetchOptions: {
            method: "GET",
            mode: "no-cors"
          }
        });
        engine.onFinished = function(result) {
          msmResults.finished = true;
          msmResults.results = _objectSpread2({
            host: msmConfig.host
          }, result);
          _this4.onResultsChange({
            type
          });
          _assertClassBrand(_MeasurementEngine_brand, _this4, _next).call(_this4);
        };
        break;
      case "rpki":
        engine = new ReachabilityEngine("https://".concat(_classPrivateFieldGet2(_config, this).rpkiInvalidHost), {
          timeout: 5e3
        });
        engine.onFinished = function(result) {
          (result.response ? result.response.json() : Promise.resolve()).then(function(response) {
            msmResults.finished = true;
            msmResults.results = _objectSpread2({
              host: _classPrivateFieldGet2(_config, _this4).rpkiInvalidHost,
              filteringInvalids: !result.reachable
            }, response ? {
              asn: response.asn,
              name: response.name
            } : {});
            _this4.onResultsChange({
              type
            });
            _assertClassBrand(_MeasurementEngine_brand, _this4, _next).call(_this4);
          });
        };
        break;
      case "nxdomain":
        engine = new ReachabilityEngine("https://".concat(msmConfig.nxhost), {
          fetchOptions: {
            mode: "no-cors"
          }
        });
        engine.onFinished = function(result) {
          msmResults.finished = true;
          msmResults.results = {
            host: msmConfig.nxhost,
            reachable: result.reachable
          };
          _this4.onResultsChange({
            type
          });
          _assertClassBrand(_MeasurementEngine_brand, _this4, _next).call(_this4);
        };
        break;
      case "packetLoss":
      case "packetLossUnderLoad":
        {
          msmResults.finished = false;
          var numMsgs = msmConfig.numPackets, ptCfg = _objectWithoutProperties(msmConfig, _excluded2);
          var _classPrivateFieldGet4 = _classPrivateFieldGet2(_config, this), turnServerUri = _classPrivateFieldGet4.turnServerUri, turnServerCredsApi = _classPrivateFieldGet4.turnServerCredsApiUrl, turnServerUser = _classPrivateFieldGet4.turnServerUser, turnServerPass = _classPrivateFieldGet4.turnServerPass, includeCredentials = _classPrivateFieldGet4.includeCredentials;
          engine = new PacketLossUnderLoadEngine(_objectSpread2({
            turnServerUri,
            turnServerCredsApi,
            turnServerCredsApiIncludeCredentials: includeCredentials,
            turnServerUser,
            turnServerPass,
            numMsgs,
            // if under load
            downloadChunkSize: msmConfig.loadDown ? _classPrivateFieldGet2(_optimalDownloadChunkSize, this) : void 0,
            uploadChunkSize: msmConfig.loadUp ? _classPrivateFieldGet2(_optimalUploadChunkSize, this) : void 0,
            downloadApiUrl,
            uploadApiUrl
          }, ptCfg));
        }
        engine.onMsgReceived = function() {
          msmResults.results = Object.assign({}, engine.results);
          _this4.onResultsChange({
            type
          });
        };
        engine.onFinished = function() {
          msmResults.finished = true;
          _this4.onResultsChange({
            type
          });
          _assertClassBrand(_MeasurementEngine_brand, _this4, _next).call(_this4);
        };
        engine.onConnectionError = function(e) {
          msmResults.error = e;
          _this4.onResultsChange({
            type
          });
          _classPrivateFieldGet2(_onError, _this4).call(_this4, "Connection error while measuring packet loss: ".concat(e));
          _assertClassBrand(_MeasurementEngine_brand, _this4, _next).call(_this4);
        };
        engine.onCredentialsFailure = function() {
          msmResults.error = "unable to get turn server credentials";
          _this4.onResultsChange({
            type
          });
          _classPrivateFieldGet2(_onError, _this4).call(_this4, "Error while measuring packet loss: unable to get turn server credentials.");
          _assertClassBrand(_MeasurementEngine_brand, _this4, _next).call(_this4);
        };
        break;
      case "latency":
      case "latencyUnderLoad":
        msmResults.finished = false;
        engine = new LoggingBandwidthEngine([{
          dir: "down",
          bytes: 0,
          count: msmConfig.numPackets,
          bypassMinDuration: true
        }], {
          downloadApiUrl,
          uploadApiUrl,
          estimatedServerTime,
          logApiUrl: _classPrivateFieldGet2(_config, this).logMeasurementApiUrl,
          measurementId: _classPrivateFieldGet2(_measurementId, this),
          sessionId: _classPrivateFieldGet2(_config, this).sessionId,
          // if under load
          downloadChunkSize: msmConfig.loadDown ? _classPrivateFieldGet2(_optimalDownloadChunkSize, this) : void 0,
          uploadChunkSize: msmConfig.loadUp ? _classPrivateFieldGet2(_optimalUploadChunkSize, this) : void 0
        });
        engine.fetchOptions = {
          credentials: _classPrivateFieldGet2(_config, this).includeCredentials ? "include" : void 0
        };
        engine.abortRequestDuration = _classPrivateFieldGet2(_config, this).bandwidthAbortRequestDuration;
        engine.onMeasurementResult = engine.onNewMeasurementStarted = function(meas, results) {
          msmResults.results = Object.assign({}, results.down[0]);
          _this4.onResultsChange({
            type
          });
        };
        engine.onFinished = function() {
          msmResults.finished = true;
          _this4.onResultsChange({
            type
          });
          _classPrivateFieldGet2(_running, _this4) && _assertClassBrand(_MeasurementEngine_brand, _this4, _next).call(_this4);
        };
        engine.onConnectionError = function(e) {
          msmResults.error = e;
          _this4.onResultsChange({
            type
          });
          _classPrivateFieldGet2(_onError, _this4).call(_this4, "Connection error while measuring latency: ".concat(e));
          _assertClassBrand(_MeasurementEngine_brand, _this4, _next).call(_this4);
        };
        engine.play();
        break;
      case "download":
      case "upload":
        if (msmResults.finished || msmResults.error) {
          _assertClassBrand(_MeasurementEngine_brand, this, _next).call(this);
        } else {
          delete msmResults.finishedCurrentRound;
          var measureParallelLatency = _classPrivateFieldGet2(_config, this)["measure".concat(type === "download" ? "Down" : "Up", "loadLoadedLatency")];
          engine = new LoggingBandwidthEngine([_objectSpread2({
            dir: type === "download" ? "down" : "up"
          }, msmConfig)], {
            downloadApiUrl,
            uploadApiUrl,
            estimatedServerTime,
            logApiUrl: _classPrivateFieldGet2(_config, this).logMeasurementApiUrl,
            measurementId: _classPrivateFieldGet2(_measurementId, this),
            measureParallelLatency,
            parallelLatencyThrottleMs: _classPrivateFieldGet2(_config, this).loadedLatencyThrottle,
            sessionId: _classPrivateFieldGet2(_config, this).sessionId
          });
          engine.fetchOptions = {
            credentials: _classPrivateFieldGet2(_config, this).includeCredentials ? "include" : void 0
          };
          engine.finishRequestDuration = _classPrivateFieldGet2(_config, this).bandwidthFinishRequestDuration;
          engine.abortRequestDuration = _classPrivateFieldGet2(_config, this).bandwidthAbortRequestDuration;
          engine.onNewMeasurementStarted = function(_ref) {
            var count = _ref.count, bytes = _ref.bytes;
            var res = msmResults.results = Object.assign({}, msmResults.results);
            !res.hasOwnProperty(bytes) && (res[bytes] = {
              timings: [],
              numMeasurements: 0,
              sideLatency: measureParallelLatency ? [] : void 0
            });
            if (res[bytes].numMeasurements - res[bytes].timings.length !== count) {
              res[bytes].numMeasurements += count;
              _this4.onResultsChange({
                type
              });
            }
          };
          engine.onMeasurementResult = function(_ref2) {
            var bytes = _ref2.bytes, timing = _objectWithoutProperties(_ref2, _excluded3);
            msmResults.results[bytes].timings.push(timing);
            msmResults.results = Object.assign({}, msmResults.results);
            _this4.onResultsChange({
              type
            });
          };
          engine.onParallelLatencyResult = function(res) {
            msmResults.results[msmConfig.bytes].sideLatency.push(res);
            msmResults.results = Object.assign({}, msmResults.results);
            _this4.onResultsChange({
              type
            });
          };
          engine.onFinished = function(results) {
            var isLastMsmOfType = !_classPrivateFieldGet2(_config, _this4).measurements.slice(_classPrivateFieldGet2(_curMsmIdx, _this4) + 1).map(function(d) {
              return d.type;
            }).includes(type);
            var minDuration = Math.min.apply(Math, _toConsumableArray(Object.values(type === "download" ? results.down : results.up).slice(-1)[0].timings.map(function(d) {
              return d.duration;
            })));
            var reachedEndOfMsmType = isLastMsmOfType || !msmConfig.bypassMinDuration && minDuration > _classPrivateFieldGet2(_config, _this4).bandwidthFinishRequestDuration;
            if (!reachedEndOfMsmType) {
              msmResults.finishedCurrentRound = true;
            } else {
              msmResults.finished = true;
              _this4.onResultsChange({
                type
              });
              var largestSize = Object.keys(msmResults.results).map(function(n) {
                return +n;
              }).sort(function(a, b) {
                return b - a;
              })[0];
              var optimalSize = largestSize * OPTIMAL_SIZE_RATIO;
              type === "download" && _classPrivateFieldSet2(_optimalDownloadChunkSize, _this4, optimalSize);
              type === "upload" && _classPrivateFieldSet2(_optimalUploadChunkSize, _this4, optimalSize);
            }
            _classPrivateFieldGet2(_running, _this4) && _assertClassBrand(_MeasurementEngine_brand, _this4, _next).call(_this4);
          };
          engine.onConnectionError = function(e) {
            msmResults.error = e;
            _this4.onResultsChange({
              type
            });
            _classPrivateFieldGet2(_onError, _this4).call(_this4, "Connection error while measuring ".concat(type, ": ").concat(e));
            _assertClassBrand(_MeasurementEngine_brand, _this4, _next).call(_this4);
          };
          engine.play();
        }
        break;
    }
    _classPrivateFieldSet2(_curEngine, this, engine);
    msmResults.started = true;
    this.onResultsChange({
      type
    });
  }
  var _logAimApiUrl = /* @__PURE__ */ new WeakMap();
  var _sessionId = /* @__PURE__ */ new WeakMap();
  var _logFinalResults = /* @__PURE__ */ new WeakMap();
  var LoggingMeasurementEngine = /* @__PURE__ */ (function(_MeasurementEngine2) {
    function LoggingMeasurementEngine2(userConfig) {
      var _this;
      _classCallCheck(this, LoggingMeasurementEngine2);
      for (var _len = arguments.length, pt = new Array(_len > 1 ? _len - 1 : 0), _key = 1; _key < _len; _key++) {
        pt[_key - 1] = arguments[_key];
      }
      _this = _callSuper(this, LoggingMeasurementEngine2, [userConfig].concat(pt));
      _classPrivateFieldInitSpec(_this, _logAimApiUrl, void 0);
      _classPrivateFieldInitSpec(_this, _sessionId, void 0);
      _classPrivateFieldInitSpec(_this, _logFinalResults, function(results) {
        _classPrivateFieldGet2(_logAimApiUrl, _this) && logAimResults(results, {
          apiUrl: _classPrivateFieldGet2(_logAimApiUrl, _this),
          sessionId: _classPrivateFieldGet2(_sessionId, _this)
        });
      });
      _superPropSet(LoggingMeasurementEngine2, "onFinish", _classPrivateFieldGet2(_logFinalResults, _this), _this, 1);
      var config = Object.assign({}, defaultConfig, userConfig, internalConfig);
      _classPrivateFieldSet2(_logAimApiUrl, _this, config.logAimApiUrl);
      _classPrivateFieldSet2(_sessionId, _this, config.sessionId);
      return _this;
    }
    _inherits(LoggingMeasurementEngine2, _MeasurementEngine2);
    return _createClass(LoggingMeasurementEngine2, [{
      key: "onFinish",
      set: function set2(onFinish) {
        var _this2 = this;
        _superPropSet(LoggingMeasurementEngine2, "onFinish", function(results) {
          onFinish(results);
          _classPrivateFieldGet2(_logFinalResults, _this2).call(_this2, results);
        }, this, 1);
      }
    }]);
  })(MeasurementEngine);
  return __toCommonJS(speedtest_exports);
})();
