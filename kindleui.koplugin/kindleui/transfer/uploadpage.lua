--[[--
The page served to the phone browser.

Plain HTML + a few lines of vanilla JS (only needed for the progress bar;
XMLHttpRequest streams the raw file as the request body, so the Kindle never
has to parse multipart/form-data). No external resources of any kind: the
phone may have no internet access at all.

@module kindleui.transfer.uploadpage
]]

local UploadPage = {}

-- Nothing may be loaded from anywhere; only inline style/script and
-- same-origin XHR are allowed.
UploadPage.CSP = "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; "
    .. "connect-src 'self'; img-src 'none'; form-action 'none'; base-uri 'none'; frame-ancestors 'none'"

local function htmlEscape(s)
    return (tostring(s):gsub("[&<>\"']", {
        ["&"] = "&amp;", ["<"] = "&lt;", [">"] = "&gt;", ['"'] = "&quot;", ["'"] = "&#39;",
    }))
end

local TEMPLATE = [[<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>{{HTML_TITLE}}</title>
<style>
*{box-sizing:border-box}
body{margin:0;padding:24px 20px;font:17px/1.45 -apple-system,system-ui,"Segoe UI",Roboto,sans-serif;color:#111;background:#fff;max-width:520px;margin:0 auto}
h1{font-size:20px;letter-spacing:.08em;margin:8px 0 28px;text-align:center}
.pick{display:block;width:100%;padding:18px;border:2px solid #111;border-radius:10px;text-align:center;font-weight:600;cursor:pointer}
input[type=file]{position:absolute;left:-9999px}
#name{margin:18px 0 8px;word-break:break-word;font-weight:600;min-height:1.4em;text-align:center}
button{width:100%;padding:16px;font:inherit;font-weight:600;border:0;border-radius:10px;background:#111;color:#fff}
button:disabled{background:#bbb}
.bar{height:14px;border:2px solid #111;border-radius:7px;overflow:hidden;margin:18px 0 6px;display:none}
.bar div{height:100%;width:0;background:#111}
#status{text-align:center;min-height:1.4em;margin-top:10px}
.coll{display:block;margin:16px 0 0;text-align:center}.coll select{font:inherit;margin-left:6px;max-width:60%}
#list{list-style:none;padding:0;margin:14px 0 0;font-size:15px}#list li{padding:4px 0;word-break:break-word}.bad{color:#a00}
.ok{font-size:19px;font-weight:700}
.note{color:#555;font-size:14px;margin-top:32px}
</style>
</head>
<body>
<h1>{{TITLE}}</h1>
<noscript><p>JavaScript is required to upload from this page.</p></noscript>
<div id="form">
<label class="pick" for="file">{{PICK}}</label>
<input id="file" type="file"{{MULTIPLE}}{{ACCEPT}}>
<div id="name"></div>
{{COLLECTIONS}}<button id="send" disabled>Upload</button>
</div>
<div class="bar" id="bar"><div id="fill"></div></div>
<div id="status" role="status" aria-live="polite"></div>
<ul id="list"></ul>
<p class="note">{{NOTE}}</p>
<script>
(function(){
var BASE="{{BASE_PATH}}",L={{STRINGS}};
var f=document.getElementById("file"),b=document.getElementById("send"),n=document.getElementById("name"),
    s=document.getElementById("status"),bar=document.getElementById("bar"),fill=document.getElementById("fill"),
    form=document.getElementById("form"),list=document.getElementById("list");
function say(t,cls){s.textContent=t;s.className=cls||"";}
function item(t,cls){var li=document.createElement("li");li.textContent=t;li.className=cls||"";list.appendChild(li);}
f.onchange=function(){var k=f.files?f.files.length:0;
  n.textContent=k===1?f.files[0].name:(k>1?k+L.sel:"");b.disabled=!k;say("");};
function finish(ok,bad,dead){
  bar.style.display="none";
  if(dead){return;}
  var r=new XMLHttpRequest();r.open("POST",BASE+"/finish",true);r.send("");
  form.style.display="none";
  if(ok&&!bad){say("\u2713 "+(ok===1?L.one:ok+L.many)+" You may close this page.","ok");}
  else if(ok){say("\u2713 "+ok+" sent, "+bad+" not sent (see below). You may close this page.","ok");}
  else{say(L.none);}
}
b.onclick=function(){
  var files=[],i;for(i=0;i<f.files.length;i++){files.push(f.files[i]);}
  if(!files.length){return;}
  b.disabled=true;f.disabled=true;if(document.getElementById("coll")){document.getElementById("coll").disabled=true;}list.textContent="";bar.style.display="block";
  var ok=0,bad=0,idx=0;
  function next(){
    if(idx>=files.length){finish(ok,bad,false);return;}
    var x=files[idx],pos=idx+1,label=(files.length>1?L.item+pos+" of "+files.length+": ":"")+x.name;idx++;
    fill.style.width="0";say("Uploading "+label+"... 0%");
    var r=new XMLHttpRequest();
    var co=document.getElementById("coll"),cq=co&&co.value?"&collection="+co.value:"";
    r.open("POST",BASE+"/upload?name="+encodeURIComponent(x.name)+"&index="+pos+"&count="+files.length+cq,true);
    r.setRequestHeader("Content-Type","application/octet-stream");
    r.upload.onprogress=function(e){if(e.lengthComputable){var p=Math.floor(e.loaded*100/e.total);fill.style.width=p+"%";say("Uploading "+label+"... "+p+"%");}};
    r.onload=function(){
      if(r.status===200){ok++;item("\u2713 "+x.name,"good");next();}
      else if(r.status===404||r.status===410){bar.style.display="none";say(r.responseText);finish(ok,bad,true);}
      else{bad++;item("\u2717 "+x.name+" \u2014 "+(r.responseText||("error "+r.status)),"bad");next();}
    };
    r.onerror=function(){bar.style.display="none";
      say("Connection to the Kindle was lost. Make sure the Send Book screen is still open, then try again.");
      b.disabled=false;f.disabled=false;};
    r.send(x);
  }
  next();
};
})();
</script>
</body>
</html>
]]

-- A JS string literal for our own constant strings (still escaped, so that
-- nothing can close the string or the <script> element).
local function jsString(v)
    return '"' .. tostring(v):gsub('[\\"<>&\n\r]', function(c)
        return string.format("\\u%04x", c:byte())
    end) .. '"'
end

-- What the page says, per kind of upload.
UploadPage.KINDS = {
    books = {
        html_title = "Send to Kindle",
        title = "SEND TO KINDLE",
        pick = "Choose Books",
        multiple = true,
        note = "Supported: {{FORMATS}}.<br>Maximum size per book: {{MAX_MB}} MB.<br>You can select several books at once. "
            .. "They go directly from this phone to the Kindle over your local Wi-Fi. No internet connection is used.",
        strings = { one = "Book sent successfully.", many = " books sent successfully.", none = "No books were sent.",
            sel = " books selected", item = "Book " },
    },
    plugin = {
        html_title = "Send plugin to Kindle",
        title = "SEND PLUGIN",
        pick = "Choose plugin .zip",
        multiple = false,
        accept = ".zip,application/zip",
        note = "Choose the plugin's .zip file (for example a GitHub \"Download ZIP\" or release asset). "
            .. "Maximum size: {{MAX_MB}} MB.<br>Nothing is installed until you confirm on the Kindle. "
            .. "It goes directly from this phone to the Kindle over your local Wi-Fi.",
        strings = { one = "Plugin sent. Confirm the install on your Kindle.", many = " files sent.",
            none = "No plugin was sent.", sel = " files selected", item = "File " },
    },
}

-- "Add to collection" picker (books only). Option values are list positions,
-- never names: the Kindle maps them back to its own list.
local function collectionPicker(collections)
    if not collections or #collections == 0 then return "" end
    local opts = { '<option value="">None</option>' }
    for i, c in ipairs(collections) do
        table.insert(opts, string.format('<option value="%d">%s</option>', i, htmlEscape(c.title or c.name)))
    end
    return '<label class="coll">Add to collection<select id="coll">' .. table.concat(opts) .. "</select></label>\n"
end

--- Renders the page.
-- @param o { base_path = "/<token>", formats = "EPUB, PDF, ...", max_mb = 500,
--            kind = "books" | "plugin", collections = { { name, title }, ... } }
function UploadPage.render(o)
    local path = tostring(o.base_path)
    -- The path is ours (hex token) but never let it break out of the JS string.
    assert(path:match("^/%w+$"), "unexpected base path")
    local kind = UploadPage.KINDS[o.kind or "books"] or UploadPage.KINDS.books
    local note = kind.note
        :gsub("{{FORMATS}}", function() return htmlEscape(o.formats or "EPUB, PDF") end)
        :gsub("{{MAX_MB}}", function() return htmlEscape(o.max_mb or 500) end)
    local strings = {}
    for __, k in ipairs({ "one", "many", "none", "sel", "item" }) do
        table.insert(strings, k .. ":" .. jsString(kind.strings[k]))
    end
    local values = {
        BASE_PATH = path,
        HTML_TITLE = htmlEscape(kind.html_title),
        TITLE = htmlEscape(kind.title),
        PICK = htmlEscape(kind.pick),
        MULTIPLE = kind.multiple and " multiple" or "",
        ACCEPT = kind.accept and (' accept="' .. htmlEscape(kind.accept) .. '"') or "",
        NOTE = note,
        COLLECTIONS = (o.kind or "books") == "books" and collectionPicker(o.collections) or "",
        STRINGS = "{" .. table.concat(strings, ",") .. "}",
    }
    return (TEMPLATE:gsub("{{([%u_]+)}}", function(key) return values[key] end))
end

return UploadPage
