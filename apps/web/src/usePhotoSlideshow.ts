import { ref, type Ref } from "vue";

type PhotoItem = {type:"photo"|"video"};
type SlideshowOptions<T extends PhotoItem> = {
  selected:Ref<T|null>;
  selectedIndex:Ref<number>;
  modalAssets:Readonly<Ref<T[]>>;
  showAssetAt:(index:number)=>void;
};

export function usePhotoSlideshow<T extends PhotoItem>({selected,selectedIndex,modalAssets,showAssetAt}:SlideshowOptions<T>) {
  const slideshow=ref(false);
  let slideshowTimer:number|undefined;
  function stopSlideshow(){
   slideshow.value=false;
   if(slideshowTimer!==undefined){window.clearInterval(slideshowTimer);slideshowTimer=undefined}
  }
  function advanceSlideshow(){
   if(!selected.value||document.hidden)return;
   const items=modalAssets.value;
   if(items.length<2){stopSlideshow();return}
   for(let step=1;step<=items.length;step++){
    const index=(selectedIndex.value+step)%items.length;
    if(items[index]?.type==="photo"){showAssetAt(index);return}
   }
   stopSlideshow();
  }
  function toggleSlideshow(){
   if(slideshow.value){stopSlideshow();return}
   if(!selected.value||modalAssets.value.length<2)return;
   slideshow.value=true;
   slideshowTimer=window.setInterval(advanceSlideshow,4000);
  }
  return {slideshow,stopSlideshow,toggleSlideshow};
}
