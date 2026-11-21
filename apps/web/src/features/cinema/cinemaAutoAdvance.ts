type EpisodeLike = {id:number;kind:string};

export async function continueAfterPlaybackEnd<T extends EpisodeLike>({
 film,
 saveFinished,
 shouldAdvance,
 isCurrent,
 findNext,
 openNext,
 onNoNext,
}: {
 film:T|null;
 saveFinished:()=>Promise<void>;
 shouldAdvance:(film:T)=>boolean;
 isCurrent:()=>boolean;
 findNext:(film:T)=>Promise<T|null>;
 openNext:(film:T)=>Promise<void>;
 onNoNext:()=>void;
}):Promise<void>{
 await saveFinished();
 if(!film||!shouldAdvance(film)||!isCurrent())return;
 const next=await findNext(film);
 if(!isCurrent())return;
 if(next)await openNext(next);
 else onNoNext();
}
