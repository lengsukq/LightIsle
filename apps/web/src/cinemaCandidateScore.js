/** Ranking produces *suggestions*, never an automatic metadata write.
 * @param {{kind:string,title:string,year?:number}} film
 * @param {{kind:string,title:string,year?:string}} candidate
 */
export function tmdbCandidateScore(film,candidate) {
  if(candidate.kind !== (film.kind==="series"?"tv":"movie"))return 0;
  const clean=(name)=>name.toLowerCase().normalize("NFKC").replace(/[\s._\-:：、，,()[\]【】]+/g,"");
  const title=clean(film.title),other=clean(candidate.title);
  const name=title===other?75:title.length>=4&&other.length>=4&&
    (title.includes(other)||other.includes(title))?48:0;
  const year=film.year>0&&candidate.year&&Number(candidate.year)===film.year?20:0;
  return name+year;
}
