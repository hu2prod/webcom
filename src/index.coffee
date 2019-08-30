module = @
require 'fy'
require 'fy/codegen'
# http          = require 'http'
express       = require 'express'
os            = require 'os'
path          = require 'path'
mod_url       = require 'url'
fs            = require 'fs'
CSON          = require 'cson'
compression   = require 'compression'
mime          = require 'mime'
range_parser  = require 'range-parser'
engine        = require './server_engine_handler'

@start_ts     = Date.now()

# LATER os path delimiter
@start = (opt)->
  if !opt.htdocs
    throw new Error "missing opt.htdocs"
  if !opt.bundle
    throw new Error "missing opt.bundle"
  opt.port ?= 8080
  opt.js_delivery ?= 'separate'
  # safe mode
  opt.css_strict_order ?= true
  opt.hotreload   ?= opt.watch
  opt.compression ?= opt.compress
  opt.compression ?= opt.gz
  opt.compression ?= opt.gzip
  opt.seekable    ?= true
  opt.seekable_threshold ?= 1e6
  
  opt.htdocs = opt.htdocs.replace /\/$/, ''
  
  server_start_time = (new Date()).toUTCString()
  
  cache = {}
  full_to_url_path = (full_path)->
    full_path = full_path.replace /^\.\//, '/'
    full_path = full_path.replace opt.htdocs, ''
    full_path
  read_c_item = (full_path, root_url_path, ignore_cache = false)->
    url_path = full_to_url_path full_path
    if !ignore_cache
      return c_item if c_item = cache[url_path]
    else
      if c_item = cache[url_path]
        root_url_path ?= c_item.root_url_path
    
    [skip, engine_name] = /\.([^\/]*?)$/.exec url_path
    code = fs.readFileSync full_path
    engine_opt = opt.engine or {}
    engine_opt.url_path = url_path.replace root_url_path, ""
    c_item = {
      engine : engine.canonical engine_name
      header_content_type : engine.mime engine_name
      body : engine.eval engine_name, code, engine_opt
      url_path
      root_url_path
    }
    # fix jade
    if engine_name != 'html' and c_item.engine == 'html'
      c_item.url_path = c_item.url_path.replace /\.(.*?)$/, ".html"
    
    # LATER compact template HERE
    cache[url_path] = c_item
  
  cache["/bundle.coffee"] = {
    engine  : 'js'
    header_content_type : engine.mime 'js'
    body    : opt.bundle.code_gen()
    url_path: "/bundle.coffee"
  }
  
  comp = compression(threshold: 10000) # 9+kb
  # server = http.createServer (req, res)-> # can't use with seekable
  server = express()
  server.use (req, res)->
    if opt.compression
      comp req, res, ->
    url = mod_url.parse req.url
    url_path = url.pathname
    url_path = url_path.replace "/..", ''
    url_path = url_path.replace /\/$/, ''
    send_c_item = (c_item)->
      if c_item.body instanceof Buffer
        res.setHeader "Content-Length", c_item.body.length
      else
        res.setHeader "Content-Length", Buffer.byteLength c_item.body, 'UTF-8'
      header_content_type = c_item.header_content_type
      header_content_type += "; charset=utf-8" unless /css/.test header_content_type
      res.setHeader "Content-Type", header_content_type
      if !opt.hotreload
        res.setHeader 'Last-Modified', server_start_time
      res.end c_item.body
      return
    
    return send_c_item c_item if c_item = cache[url_path]
    
    loop
      full_path = opt.htdocs+url_path
      await fs.exists full_path, defer(exists)
      break if exists
      
      full_path = "./"+url_path
      await fs.exists full_path, defer(exists)
      break if exists
      
      res.end 'not exists'
      return
    await fs.stat full_path, defer(err, stat) ; throw err if err
    if stat.isDirectory()
      if url.pathname[url.pathname.length - 1] != "/"
        # Redirrect ибо не будут работать относительные пути
        res.setHeader 'Location', url_path+"/"
        res.writeHead 302
        res.end()
        # return res.redirect(url_path+"/") # так можно в express
        return
      style_list = []
      style_hash = {}
      # template_hash = {}
      script_list = []
    
      file_hash = {}
      file_arg_list = []
      recursive_read = (path, root_path, file_filter, file_filter_condition)->
        root_path ?= url_path
        conf = {}
        path_to_config = path+"/.config"
        if fs.existsSync path_to_config
          try
            conf = CSON.parse fs.readFileSync path_to_config
          catch e
            perr "[ERROR] invalid config #{path_to_config}"
        
        conf.require_list ?= []
        conf.ignore_list ?= []
        for dir,k in conf.ignore_list
          conf.ignore_list[k] = "#{path}/#{dir}"
        
        for dir in conf.require_list
          recursive_read "#{opt.htdocs}/#{dir}", "/#{dir}", file_filter, file_filter_condition
        
        for file in fs.readdirSync path
          continue if file == '.config'
          real_path = "#{path}/#{file}"
          continue if conf.ignore_list.has real_path
          stat = fs.lstatSync real_path
          
          if stat.isDirectory()
            recursive_read real_path, root_path, file_filter, file_filter_condition
          else
            continue if file_filter and file_filter_condition != file_filter.test file
            continue if file_hash[real_path]
            file_hash[real_path] = true
            file_arg_list.push [real_path, root_path]
        return
      
      vendor_path = "node_modules/webcom-engine-vendor"
      if opt.vendor
        recursive_read "./#{vendor_path}/#{opt.vendor}"
      if fs.existsSync full_path+"/#{vendor_path}"
        recursive_read full_path+"/#{vendor_path}"
      file_arg_list.push ["/bundle.coffee"]
      recursive_read full_path, url_path, /\.com\.coffee$/, true
      recursive_read full_path, url_path, /\.com\.coffee$/, false
      
      url_file_list = ["#{url_path}/.config"]
      for file_arg in file_arg_list
        if opt.seekable
          path = file_arg[0]
          if path != '/bundle.coffee'
            stat = fs.statSync path
            continue if stat.size > opt.seekable_threshold
        
        c_item = read_c_item file_arg...
        switch c_item.engine
          # when 'html'
            # template_hash[c_item.url_path] = c_item.body
          when 'js'
            switch opt.js_delivery
              when 'separate'
                url_file_list.push c_item.url_path
                script_list.upush "<script src=\"#{c_item.url_path}\"></script>"
              # when 'join'
                # script_list.upush "<script>#{c_item.body}</script>"
          when 'css'
            style_hash[c_item.url_path] = c_item.body
            style_list.push c_item.body
      
      hot_reload_code = ""
      if opt.hotreload
        hot_reload_code = """
          var config_hot_reload = #{JSON.stringify opt.hotreload};
          var config_hot_reload_port = #{JSON.stringify opt.ws_port};
          var start_ts = #{JSON.stringify module.start_ts};
          var file_list = #{JSON.stringify url_file_list};
          """
      
      # TODO LATER opt.index_html
      body = """
        <!DOCTYPE html>
        <html>
          <head>
            <meta charset=\"utf-8\">
            #{opt.head or ''}
            <title>#{opt.title or 'Webcom delivery'}</title>
            <style>
              #{join_list style_list, '      '}
            </style>
          </head>
          <body>
            <div id=\"mount_point\"></div>
            <script>
              #{make_tab hot_reload_code, '      '}
              var framework_style_hash = #{JSON.stringify style_hash};
            </script>
            #{join_list script_list, '    '}
          </body>
        </html>
        """
      # var framework_template_hash = #{JSON.stringify template_hash};
      return send_c_item {
        header_content_type : engine.mime 'html'
        body
      }
    else
      if stat.size < opt.seekable_threshold and !req.headers.range # ~1 Mb
        send_c_item read_c_item full_path
      else
        res.set 'Accept-Ranges', 'bytes'
        res.set 'Content-Length', stat.size
        res.set 'Content-Type',   mime.getType full_path
        if req.headers.range
          ranges = range_parser stat.size, req.headers.range
          return res.sendStatus(400) if ranges == -2 # malformed range
          if ranges == -1
            # unsatisfiable range
            res.set 'Content-Range', '*/' + stat.size
            return res.sendStatus(416)
          
          if ranges.type != 'bytes'
            return fs.createReadStream(full_path).pipe res
          if ranges.length > 1
            res.end 'send-seekable can only serve single ranges'
          {start, end} = ranges[0]
          res.status 206
          res.set 'Content-Length', (end - start) + 1
          res.set 'Content-Range', 'bytes ' + start + '-' + end + '/' + stat.size
          fs.createReadStream(full_path, {start, end}).pipe res
        else
          fs.createReadStream(full_path).pipe res
    return
  
  server.listen opt.port, ()->
    puts "[INFO] Webcom delivery server started. Try on any of this adresses:"
    for k,list of os.networkInterfaces()
      for v in list
        continue if v.family != 'IPv4'
        continue if v.address == '127.0.0.1'
        puts "[INFO]   http://#{v.address}:#{opt.port}"
    opt.on_end?()
    return
  # ###################################################################################################
  #    watch
  # ###################################################################################################
  if opt.hotreload
    WebSocketServer = require('ws').Server
    wss = new WebSocketServer
      port: opt.ws_port or opt.port+1
    hotreload_full = ()->
      return {
        switch  : "hotreload_full"
        start_ts: module.start_ts
      }
    wss.on 'connection', (con)->
      con.write = (msg)->
        if typeof msg == 'string' or msg instanceof Buffer
          return con.send msg, (err)->
            perr 'ws', err if err
        return con.send JSON.stringify(msg), (err)->
          perr 'ws', err if err
      con.write hotreload_full()
      return
    
    wss.write = (msg)->
      # for con in wss.clients
        # con.write msg
      wss.clients.forEach (con)-> # FUCK ws@2.2.0
        con.write msg
      return
    
    chokidar = require 'chokidar'
    watch_dir = if opt.watch_root then "." else opt.htdocs
    watcher = chokidar.watch watch_dir, opt.chokidar or {}
    handler = (event, full_path)->
      if path.sep != '/'
        full_path = full_path.split(path.sep).join('/')
      return if /^\.git/.test full_path
      setTimeout ()->
        puts "[INFO] #{event.ljust 8} #{full_path}"
        if -1 == full_path.indexOf opt.htdocs
          puts "[INFO] non htdocs file changes"
          if opt.allow_hard_stop
            process.exit()
          return
        
        if event == 'unlink'
          url_path = full_to_url_path full_path
          c_item = {
            engine : engine.canonical url_path
            url_path : url_path
            body : ''
          }
        else
          c_item = read_c_item full_path, null, true
        switch c_item.engine
          when 'html'
            wss.write {
              switch : "hotreload_template"
              path   : c_item.url_path
              content: c_item.body
              event
            }
          when 'css'
            if opt.css_strict_order and event in ['add', 'unlink']
              puts "[INFO] css_strict_order reload"
              module.start_ts = Date.now()
              wss.write hotreload_full()
            else
              wss.write {
                switch : "hotreload_style"
                path   : c_item.url_path
                content: c_item.body
                event
              }
          when 'js'
            module.start_ts = Date.now()
            wss.write {
              switch  : "hotreload_js"
              start_ts: module.start_ts
              path    : c_item.url_path
              event
            }
          else
            module.start_ts = Date.now()
            wss.write {
              switch  : "hotreload_js"
              start_ts: module.start_ts
              path    : c_item.url_path
              event
            }
        return
      , 100 # because IDE/nfs can be not so fast
      return
    watcher.on 'unlink', (path)-> handler 'unlink', path
    watcher.on 'change', (path)-> handler 'change', path
    
    is_ready = false
    on_ready = ()->
      return if is_ready
      is_ready = true
      puts "[INFO] watcher scan ready"
      watcher.on 'add', (path)-> handler 'add', path
      opt.on_watcher_ready?()
      return
    
    timeout = null
    upd_ready_timer = ()->
      clearTimeout timeout if timeout?
      timeout = setTimeout on_ready, 5000 # Прим. это всего лишь recovery. chokidar в первую очередь должен попытаться решить это всё сам
      return
    watcher.on 'add', (path)->
      # p "ADD", path
      upd_ready_timer()
    puts "[INFO] watcher start..."
    watcher.on 'ready', on_ready
  {
    stop : ()->
      server.close()
      wss?.close() # NOTE didn't work
      watcher?.close()
  }
