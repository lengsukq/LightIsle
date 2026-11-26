import { computed, ref, watch, type Ref } from "vue";
import { createViewerImageLoader } from "./viewerImageLoader.ts";
import {
  clampPanOffset,
  doubleTapZoom,
  horizontalSwipeResistance,
  normalizeViewerTransform,
  pinchDistance,
  pinchScale,
  swipeDirection,
  wheelZoomFactor,
  zoomAtAnchor,
} from "./viewerGestures.ts";

type ViewerAsset = {id:number;name:string;path:string;type:"photo"|"video"};
type ViewerOptions<T extends ViewerAsset> = {
  selected:Ref<T|null>;
  mediaPath:(path:string)=>string;
  original:(asset:T)=>string;
  thumb:(asset:T)=>string;
  preview?:(asset:T)=>string;
  move:(direction:-1|1)=>boolean;
  canMove?:(direction:-1|1)=>boolean;
};

export function usePhotoViewer<T extends ViewerAsset>({selected,mediaPath,original,thumb,preview,move,canMove}:ViewerOptions<T>) {
  // Default to a bounded preview; request the original only for zoom or an
  // explicit quality choice. Each stage has one cancellable preloader.
  const viewerStage=ref<"thumb"|"preview"|"original">("thumb");
  const viewerScale=ref(1);
  const viewerOffset=ref({x:0,y:0});
  const swipeDragX=ref(0);
  let viewerGeneration=0;
  const viewerTransform=computed(()=>{
    const dragX=viewerScale.value<=1?swipeDragX.value:0;
    return `translate3d(${viewerOffset.value.x+dragX}px,${viewerOffset.value.y}px,0) scale(${viewerScale.value})`;
  });
  function browserDecodable(asset:T){return /\.(jpe?g|png|gif|webp)$/i.test(asset.name);}
  function viewerSource(asset:T){return preview ? preview(asset) : mediaPath("/api/v2/files/thumbnail?path="+encodeURIComponent(asset.path)+"&size=2048");}
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
    swipeDragX.value=0;swipeOrigin=null;swipeAxisLocked=null;panning=false;pinchStart=null;
  }
  function startViewerStages(asset:T){
    cancelViewerLoads();
    const generation=viewerGeneration;
    viewerStage.value="thumb";viewerScale.value=1;viewerOffset.value={x:0,y:0};swipeDragX.value=0;
    if(asset.type!=="photo")return;
    viewerPreviewLoading.value=true;
    void previewLoader.load(viewerSource(asset)).then(ok=>{
      if(generation!==viewerGeneration||selected.value?.id!==asset.id)return;
      viewerPreviewLoading.value=false;viewerPreviewError.value=!ok;
      if(ok&&viewerStage.value!=="original"){
        viewerStage.value="preview";
        if(browserDecodable(asset))requestViewerOriginal();
      }else if(!ok&&browserDecodable(asset)){
        requestViewerOriginal();
      }
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
  function measureStageAndMedia(element:HTMLElement){
    const rect=element.getBoundingClientRect();
    const stageSize={width:rect.width||1,height:rect.height||1};
    const img=element.querySelector<HTMLImageElement>(".gallery-modal-image");
    let mediaSize={width:stageSize.width,height:stageSize.height};
    if(img&&img.naturalWidth>0&&img.naturalHeight>0){
      const fitScale=Math.min(stageSize.width/img.naturalWidth,stageSize.height/img.naturalHeight);
      mediaSize={width:img.naturalWidth*fitScale,height:img.naturalHeight*fitScale};
    }else if(img&&img.clientWidth>0&&img.clientHeight>0){
      mediaSize={width:img.clientWidth,height:img.clientHeight};
    }
    return {rect,stageSize,mediaSize};
  }
  function toggleViewerZoom(event?:MouseEvent|PointerEvent){
    viewerAnimate.value=true;
    swipeDragX.value=0;
    if(event&&event.currentTarget instanceof HTMLElement){
      const element=event.currentTarget;
      const anchor=viewerCenteredAnchor(event,element);
      const {stageSize,mediaSize}=measureStageAndMedia(element);
      const zoomed=clampPanOffset(doubleTapZoom({scale:viewerScale.value,x:viewerOffset.value.x,y:viewerOffset.value.y},anchor,2.5),stageSize,mediaSize);
      viewerScale.value=zoomed.scale;viewerOffset.value={x:zoomed.x,y:zoomed.y};
      return;
    }
    viewerScale.value=viewerScale.value>1?1:2.5;
    if(viewerScale.value===1)viewerOffset.value={x:0,y:0};
  }
  // Pointer gestures: two fingers pinch-zoom around their midpoint, one finger
  // pans while zoomed (bounded) and swipes horizontally when at unity, the wheel
  // zooms around the cursor. viewerAnimate keeps CSS transitions for discrete
  // actions only so continuous gestures stay glued to the fingers.
  const viewerAnimate=ref(true);
  const viewerPointers=new Map<number,{x:number;y:number}>();
  let pinchStart:{distance:number;scale:number;offset:{x:number;y:number};anchor:{x:number;y:number}}|null=null;
  let panOrigin={x:0,y:0};
  let panning=false;
  let swipeOrigin:{x:number;y:number}|null=null;
  let swipeAxisLocked:"h"|"v"|null=null;
  let lastTap:{time:number;x:number;y:number}|null=null;
  let activeStageBounds:{stageSize:{width:number;height:number};mediaSize:{width:number;height:number}}|null=null;
  function viewerCenteredAnchor(event:{clientX:number;clientY:number},element:HTMLElement){
    const rect=element.getBoundingClientRect();
    return {x:event.clientX-(rect.left+rect.width/2),y:event.clientY-(rect.top+rect.height/2)};
  }
  function viewerApply(state:{scale:number;x:number;y:number},element?:HTMLElement|null){
    const bounds=element?measureStageAndMedia(element):activeStageBounds;
    const normalized=bounds?clampPanOffset(state,bounds.stageSize,bounds.mediaSize):normalizeViewerTransform(state);
    viewerScale.value=normalized.scale;viewerOffset.value={x:normalized.x,y:normalized.y};
  }
  function viewerPointerDown(event:PointerEvent){
    const element=event.currentTarget as HTMLElement;
    activeStageBounds=measureStageAndMedia(element);
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
      swipeOrigin=null;swipeAxisLocked=null;swipeDragX.value=0;panning=false;
    }else if(viewerPointers.size===1){
      viewerAnimate.value=false;
      if(viewerScale.value>1){
        panning=true;
        panOrigin={x:event.clientX-viewerOffset.value.x,y:event.clientY-viewerOffset.value.y};
      }else{
        swipeOrigin={x:event.clientX,y:event.clientY};
        swipeAxisLocked=null;
        swipeDragX.value=0;
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
    if(panning){
      const rawX=event.clientX-panOrigin.x;
      const rawY=event.clientY-panOrigin.y;
      if(activeStageBounds){
        const clamped=clampPanOffset({scale:viewerScale.value,x:rawX,y:rawY},activeStageBounds.stageSize,activeStageBounds.mediaSize);
        viewerOffset.value={x:clamped.x,y:clamped.y};
      }else{
        viewerOffset.value={x:rawX,y:rawY};
      }
      return;
    }
    if(viewerScale.value<=1&&swipeOrigin){
      const dx=event.clientX-swipeOrigin.x;
      const dy=event.clientY-swipeOrigin.y;
      if(!swipeAxisLocked&&Math.hypot(dx,dy)>8){
        swipeAxisLocked=Math.abs(dx)>=Math.abs(dy)*1.15?"h":"v";
      }
      if(swipeAxisLocked==="h"){
        const prevOk=canMove?canMove(-1):true;
        const nextOk=canMove?canMove(1):true;
        swipeDragX.value=horizontalSwipeResistance(dx,prevOk,nextOk);
      }
    }
  }
  function viewerPointerUp(event:PointerEvent){
    const element=event.currentTarget as HTMLElement|null;
    viewerPointers.delete(event.pointerId);
    if(viewerPointers.size<2)pinchStart=null;
    if(viewerPointers.size>0)return;
    panning=false;
    const wasTap=swipeOrigin&&Math.hypot(event.clientX-swipeOrigin.x,event.clientY-swipeOrigin.y)<12&&Math.abs(swipeDragX.value)<12;
    if(wasTap&&event.pointerType!=="mouse"&&element){
      const now=Date.now();
      if(lastTap&&now-lastTap.time<280&&Math.hypot(event.clientX-lastTap.x,event.clientY-lastTap.y)<28){
        lastTap=null;
        swipeOrigin=null;swipeAxisLocked=null;swipeDragX.value=0;
        toggleViewerZoom(event);
        return;
      }
      lastTap={time:now,x:event.clientX,y:event.clientY};
    }
    if(viewerScale.value<=1&&swipeOrigin){
      const direction=swipeDirection(swipeOrigin,{x:event.clientX,y:event.clientY});
      swipeOrigin=null;swipeAxisLocked=null;swipeDragX.value=0;
      if(direction==="left"&&move(1))return;
      if(direction==="right"&&move(-1))return;
    }
    swipeOrigin=null;swipeAxisLocked=null;swipeDragX.value=0;
    viewerAnimate.value=true;
    viewerApply({scale:viewerScale.value,x:viewerOffset.value.x,y:viewerOffset.value.y},element);
  }
  function viewerWheel(event:WheelEvent){
    if(selected.value?.type!=="photo")return;
    event.preventDefault();
    viewerAnimate.value=false;
    const element=event.currentTarget as HTMLElement;
    activeStageBounds=measureStageAndMedia(element);
    const anchor=viewerCenteredAnchor(event,element);
    viewerApply(zoomAtAnchor({scale:viewerScale.value,x:viewerOffset.value.x,y:viewerOffset.value.y},wheelZoomFactor(event.deltaY),anchor),element);
  }
  return {viewerStage,viewerScale,viewerOffset,viewerTransform,viewerAnimate,viewerPointers,swipeDragX,
    viewerPreviewLoading,viewerPreviewError,viewerOriginalLoading,viewerOriginalError,
    browserDecodable,cancelViewerLoads,startViewerStages,requestViewerOriginal,viewerSrc,
    toggleViewerZoom,viewerPointerDown,viewerPointerMove,viewerPointerUp,viewerWheel};
}
