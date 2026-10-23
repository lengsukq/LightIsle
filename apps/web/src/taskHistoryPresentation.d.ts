type TaskRunPresentation = {running:boolean;lastError:string};

export function taskOperationLabel(operation:string):string;
export function taskRunStatusLabel(run:TaskRunPresentation):string;
export function taskHistoryErrorLabel(error:string|undefined):string;
