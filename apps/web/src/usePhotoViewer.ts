import { computed, ref, watch, type Ref } from "vue";
import { createViewerImageLoader } from "./viewerImageLoader.js";
import { normalizeViewerTransform, pinchDistance, pinchScale, swipeDirection, wheelZoomFactor, zoomAtAnchor } from "./viewerGestures.js";

type ViewerAsset = {id:number;name:string;path:string;type:"photo"|"video"};
type ViewerOptions<T extends ViewerAsset> = {
  selected:Ref<T|null>;
  mediaPath:(path:string)=>string;
  original:(asset:T)=>string;
  thumb:(asset:T)=>string;
  move:(direction:-1|1)=>boolean;
};

export function usePhotoViewer<T extends ViewerAsset>({selected,mediaPath,original,thumb,move}:ViewerOptions<T>) {
  // Default to a bounded preview; request the original only for zoom or an
  // explicit quality choice. Each stage has one cancellable preloader.
  const viewerStage=ref<"thumb"|"preview"|"original">("thumb");
  const viewerScale=ref(1);
  const viewerOffset=ref({x:0,y:0});
  let viewerGeneration=0;
  const viewerTransform=computed(()=>`translate(${viewerOffset.value.x}px,${viewerOffset.value.y}px) scale(${viewerScale.value})`);
  function browserDecodable(asset:T){return /\.(jpe?g|png|gif|webp)$/i.test(asset.name);}
  function viewerSource(asset:T){return mediaPath("/api/v2/files/thumbnail?path="+encodeURIComponent(asset.path)+"&size=2048");}
  const previewLoader=createViewerImageLoader();
  const originalLoader=createViewerImageLoader();
  const viewerPreviewLoading=ref(false);
  const viewerPreviewError=ref(false);
  const viewerOriginalLoading=ref(false);
  const viewerOriginalError=ref(false);
  function cancelViewerLoads(){
    viewerGeneration+=1;
    previewLoader.cancel();originalLoader.cancel();
    viewerOriginalLoading.value=false;viewerOriginalError.value=false;
    viewerPreviewLoading.value=false;viewerPreviewError.value=false;
    viewerPointers.clear();
  }
  function startViewerStages(asset:T){
    cancelViewerLoads();
    const generation=viewerGeneration;
    viewerStage.value="thumb";viewerScale.value=1;viewerOffset.value={x:0,y:0};
    if(asset.type!=="photo")return;
    viewerPreviewLoading.value=true;
    void previewLoader.load(viewerSource(asset)).then(ok=>{
      if(generation!==viewerGeneration||selected.value?.id!==asset.id)return;
      viewerPreviewLoading.value=false;viewerPreviewError.value=!ok;
      if(ok&&viewerStage.value!=="original")viewerStage.value="preview";
    });
  }
  function requestViewerOriginal(){
    const asset=selected.value;
    if(!asset||asset.type!=="photo"||!browserDecodable(asset)||viewerStage.value==="original"||viewerOriginalLoading.value)return;
    const generation=viewerGeneration;
    viewerOriginalLoading.value=true;viewerOriginalError.value=false;
    void originalLoader.load(original(asset)).then(ok=>{
      if(generation!==viewerGeneration||selected.value?.id!==asset.id)return;
      viewerOriginalLoading.value=false;viewerOriginalError.value=!ok;
      if(ok)viewerStage.value="original";
    });
  }
  watch(viewerScale,scale=>{if(scale>1)requestViewerOriginal()});
  function viewerSrc(asset:T){
    if(viewerStage.value==="thumb")return thumb(asset);
    if(viewerStage.value==="preview")return viewerSource(asset);
    return original(asset);
  }
  function toggleViewerZoom(){
    viewerAnimate.value=true;
    viewerScale.value=viewerScale.value>1?1:2.5;
    if(viewerScale.value===1)viewerOffset.value={x:0,y:0};
  }
  // Pointer gestures: two fingers pinch-zoom around their midpoint, one finger
  // pans while zoomed and flips photos when at unity, the wheel zooms around
  // the cursor. viewerAnimate keeps CSS transitions for discrete actions only
  // so continuous gestures stay glued to the fingers.
  const viewerAnimate=ref(true);
  const viewerPointers=new Map<number,{x:number;y:number}>();
  let pinchStart:{distance:number;scale:number;offset:{x:number;y:number};anchor:{x:number;y:number}}|null=null;
  let panOrigin={x:0,y:0};
  let panning=false;
  let swipeOrigin:{x:number;y:number}|null=null;
  function viewerCenteredAnchor(event:{clientX:number;clientY:number},element:HTMLElement){
    const rect=element.getBoundingClientRect();
    return {x:event.clientX-(rect.left+rect.width/2),y:event.clientY-(rect.top+rect.height/2)};
  }
  function viewerApply(state:{scale:number;x:number;y:number}){
    const normalized=normalizeViewerTransform(state);
    viewerScale.value=normalized.scale;viewerOffset.value={x:normalized.x,y:normalized.y};
  }
  function viewerPointerDown(event:PointerEvent){
    const element=event.currentTarget as HTMLElement;
    viewerPointers.set(event.pointerId,{x:event.clientX,y:event.clientY});
    element.setPointerCapture(event.pointerId);
    if(viewerPointers.size===2){
      const fingers=[...viewerPointers.values()];
      const [first,second]=fingers;
      pinchStart={
        distance:pinchDistance(first,second),
        scale:viewerScale.value,
        offset:{...viewerOffset.value},
        anchor:{
          x:(first.x+second.x)/2,y:(first.y+second.y)/2,
        },
      };
      // Convert the midpoint to the viewer's centered coordinates once.
      const rect=element.getBoundingClientRect();
      pinchStart.anchor={x:pinchStart.anchor.x-(rect.left+rect.width/2),y:pinchStart.anchor.y-(rect.top+rect.height/2)};
      swipeOrigin=null;panning=false;
    }else if(viewerPointers.size===1){
      viewerAnimate.value=false;
      if(viewerScale.value>1){
        panning=true;
        panOrigin={x:event.clientX-viewerOffset.value.x,y:event.clientY-viewerOffset.value.y};
      }else{
        swipeOrigin={x:event.clientX,y:event.clientY};
      }
    }
  }
  function viewerPointerMove(event:PointerEvent){
    if(!viewerPointers.has(event.pointerId))return;
    viewerPointers.set(event.pointerId,{x:event.clientX,y:event.clientY});
    if(pinchStart&&viewerPointers.size>=2){
      const fingers=[...viewerPointers.values()];
      const target=pinchScale(pinchStart.scale,pinchStart.distance,pinchDistance(fingers[0],fingers[1]));
      viewerApply(zoomAtAnchor({scale:pinchStart.scale,x:pinchStart.offset.x,y:pinchStart.offset.y},target/pinchStart.scale||1,pinchStart.anchor));
      return;
    }
    if(panning)viewerOffset.value={x:event.clientX-panOrigin.x,y:event.clientY-panOrigin.y};
  }
  function viewerPointerUp(event:PointerEvent){
    viewerPointers.delete(event.pointerId);
    if(viewerPointers.size<2)pinchStart=null;
    if(viewerPointers.size>0)return;
    panning=false;
    if(viewerScale.value<=1&&swipeOrigin){
      const direction=swipeDirection(swipeOrigin,{x:event.clientX,y:event.clientY});
      swipeOrigin=null;
      if(direction==="left"&&move(1))return;
      if(direction==="right"&&move(-1))return;
    }
    swipeOrigin=null;
    viewerAnimate.value=true;
    viewerApply({scale:viewerScale.value,x:viewerOffset.value.x,y:viewerOffset.value.y});
  }
  function viewerWheel(event:WheelEvent){
    if(selected.value?.type!=="photo")return;
    event.preventDefault();
    viewerAnimate.value=false;
    const element=event.currentTarget as HTMLElement;
    const anchor=viewerCenteredAnchor(event,element);
    viewerApply(zoomAtAnchor({scale:viewerScale.value,x:viewerOffset.value.x,y:viewerOffset.value.y},wheelZoomFactor(event.deltaY),anchor));
  }
  return {viewerStage,viewerScale,viewerOffset,viewerTransform,viewerAnimate,viewerPointers,
    viewerPreviewLoading,viewerPreviewError,viewerOriginalLoading,viewerOriginalError,
    browserDecodable,cancelViewerLoads,startViewerStages,requestViewerOriginal,viewerSrc,
    toggleViewerZoom,viewerPointerDown,viewerPointerMove,viewerPointerUp,viewerWheel};
}
