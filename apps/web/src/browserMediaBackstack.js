// Browser Back should close the innermost media layer first. Each layer is a
// same-URL history entry, preserving ordinary page navigation. A failed
// progress save may reject Back and restore the layer entry.
export function createBrowserMediaBackstack(host, owner, onBack) {
  let depth=0;
  let busy=false;
  const key="__lightisleMediaLayer";
  const current=()=>host.history.state?.[key];
  const stateFor=level=>({...host.history.state,[key]:{owner,level}});
  function push(){
    if(busy)return;
    const next=depth+1;
    host.history.pushState(stateFor(next),"",host.location.href);
    depth=next;
  }
  async function pop(event){
    if(!depth||busy)return;
    const marker=event.state?.[key];
    const target=marker?.owner===owner&&Number.isInteger(marker.level)
      ?Math.max(0,marker.level):0;
    if(target>=depth)return;
    const old=depth;
    busy=true;
    try{
      const success=await onBack(old,target);
      if(success)depth=target;
      else host.history.pushState(stateFor(old),"",host.location.href);
    }catch{
      host.history.pushState(stateFor(old),"",host.location.href);
    }finally{busy=false}
  }
  host.addEventListener("popstate",pop);
  return {
    push,
    get depth(){return depth},
    back(steps=1){
      if(depth&&!busy)host.history.go(-Math.min(depth,Math.max(1,steps)));
      return depth>0;
    },
    reset(){
      if(current()?.owner===owner){
        const state={...host.history.state};
        delete state[key];
        host.history.replaceState(state,"",host.location.href);
      }
      depth=0;
    },
    dispose(){
      host.removeEventListener("popstate",pop);
      this.reset();
    },
  };
}
