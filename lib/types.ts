export type Assembly={source:string;rules:string;terms:{term:string;definition:string}[];examples:{input:string;output:unknown}[];covers:{id:string;description:string}[]};
export type Step={id?:number;use_app_context?:boolean;assembly?:Assembly|null;name:string;instructions:string;model_id:number|null;format:'text'|'json';model?:string;credential_env?:string};
export type Chain={id:number;weight?:number;name:string;description:string;revision:string;steps:Step[]};
export type Model={id:number;name:string;identifier:string};
export type Result={input:string;prompt:string;output:string;model:string;ms:number;tokens?:number;error?:string};
export type Run={id:string;status:string;input:{text:string;image?:string};snapshot:Chain;results:Result[];error?:string;claim?:string;created_at:string};
