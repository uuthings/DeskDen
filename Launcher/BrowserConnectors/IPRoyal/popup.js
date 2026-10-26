const toggle=document.getElementById('toggle'), status=document.getElementById('status');
let enabled=false;
async function refresh(){const s=await chrome.storage.local.get(['enabled','statusText']);enabled=s.enabled===true;toggle.textContent=enabled?'关闭连接':'启用连接';status.textContent=s.statusText||'请安装本机连接文件，然后启用连接';}
toggle.addEventListener('click',async()=>{toggle.disabled=true;try{await chrome.runtime.sendMessage({type:'setEnabled',enabled:!enabled});await refresh();}finally{toggle.disabled=false;}});
chrome.storage.onChanged.addListener(refresh);refresh();
