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
<title>Send to Kindle</title>
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
.ok{font-size:19px;font-weight:700}
.note{color:#555;font-size:14px;margin-top:32px}
</style>
</head>
<body>
<h1>SEND TO KINDLE</h1>
<noscript><p>JavaScript is required to upload from this page.</p></noscript>
<div id="form">
<label class="pick" for="file">Choose File</label>
<input id="file" type="file">
<div id="name"></div>
<button id="send" disabled>Upload</button>
</div>
<div class="bar" id="bar"><div id="fill"></div></div>
<div id="status" role="status" aria-live="polite"></div>
<p class="note">Supported: {{FORMATS}}.<br>Maximum size: {{MAX_MB}} MB.<br>The file goes directly from this phone to the Kindle over your local Wi-Fi. No internet connection is used.</p>
<script>
(function(){
var URL_PATH="{{UPLOAD_PATH}}";
var f=document.getElementById("file"),b=document.getElementById("send"),n=document.getElementById("name"),
    s=document.getElementById("status"),bar=document.getElementById("bar"),fill=document.getElementById("fill"),
    form=document.getElementById("form");
function say(t,cls){s.textContent=t;s.className=cls||"";}
f.onchange=function(){var x=f.files&&f.files[0];n.textContent=x?x.name:"";b.disabled=!x;say("");};
b.onclick=function(){
  var x=f.files&&f.files[0]; if(!x){return;}
  b.disabled=true; f.disabled=true; bar.style.display="block"; fill.style.width="0"; say("Uploading... 0%");
  var r=new XMLHttpRequest();
  r.open("POST",URL_PATH+"?name="+encodeURIComponent(x.name),true);
  r.setRequestHeader("Content-Type","application/octet-stream");
  r.upload.onprogress=function(e){if(e.lengthComputable){var p=Math.floor(e.loaded*100/e.total);fill.style.width=p+"%";say("Uploading... "+p+"%");}};
  r.onload=function(){
    if(r.status===200){fill.style.width="100%";form.style.display="none";bar.style.display="none";
      say("✓ Book sent successfully. You may close this page.","ok");}
    else{bar.style.display="none";say(r.responseText||("Upload failed ("+r.status+")."));
      if(r.status!==404&&r.status!==410){b.disabled=false;f.disabled=false;}}
  };
  r.onerror=function(){bar.style.display="none";say("Connection to the Kindle was lost. Make sure the Send Book screen is still open, then try again.");b.disabled=false;f.disabled=false;};
  r.send(x);
};
})();
</script>
</body>
</html>
]]

--- Renders the page.
-- @param o { upload_path = "/<token>/upload", formats = "EPUB, PDF, ...", max_mb = 500 }
function UploadPage.render(o)
    local path = tostring(o.upload_path)
    -- The path is ours (hex token) but never let it break out of the JS string.
    assert(path:match("^[/%w]+$"), "unexpected upload path")
    local page = TEMPLATE
        :gsub("{{UPLOAD_PATH}}", function() return path end)
        :gsub("{{FORMATS}}", function() return htmlEscape(o.formats or "EPUB, PDF") end)
        :gsub("{{MAX_MB}}", function() return htmlEscape(o.max_mb or 500) end)
    return page
end

return UploadPage
