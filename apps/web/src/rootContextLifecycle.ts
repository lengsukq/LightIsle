/**
 * Owns the request lifetime for the selected physical NAS root.
 *
 * Every root switch (including a reselected disk with a new generation)
 * creates a fresh signal and epoch. The UI retains the root's ID, generation
 * and the cancellation of upload sessions; this class only manages network
 * request lifetimes and stale discovery response identity.
 */
export function createRootContextLifecycle() {
  let epoch=0;
  let discoveryRequest=0;
  let controller=new AbortController();
  return {
    get epoch(){return epoch;},
    get signal(){return controller.signal;},
    invalidate():number {
      controller.abort();
      controller=new AbortController();
      return ++epoch;
    },
    beginDiscovery():number {return ++discoveryRequest;},
    invalidateDiscovery():void {discoveryRequest++;},
    isCurrentDiscovery(request:number):boolean {
      return request===discoveryRequest;
    },
    isCurrentEpoch(value:number):boolean {return value===epoch;},
  };
}
