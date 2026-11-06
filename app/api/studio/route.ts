import {authClient} from '@/lib/supabase';
import {stepMessages} from '@/lib/messages';
import type {Run} from '@/lib/types';
export const maxDuration=60;
export async function POST(request:Request){
 if(request.headers.get('origin')!==new URL(request.url).origin)return Response.json({error:'Invalid origin.'},{status:403});
 const db=await authClient();const {data:{user}}=await db.auth.getUser();if(!user)return Response.json({error:'Sign in required.'},{status:401});
 const {data:admin}=await db.rpc('week6_admin_me');if(!admin?.authorized)return Response.json({error:'Admin access required.'},{status:403});
 async function rpc(action:string,p:unknown){const {data,error}=await db.rpc('studio_lab_command',{action,p});if(error)throw Error(error.message);return data;}
 try{
 if(Number(request.headers.get('content-length'))>3200000)throw Error('Image is too large.');
 const {action,p={}}=await request.json();
 if(!['list','save','delete','runs','run','start','advance','library-save','import'].includes(action))throw Error('Invalid action.');
 if(action==='import'){const {data,error}=await db.rpc('studio_import_to_admin',{p_chain:p.id,p_revision:p.revision});if(error)throw Error(error.message);return Response.json(data);}
 if(action==='list')return Response.json(await rpc('list',{}));
 if(action==='start'){
 const image=p.input?.image;if(image&&!/^data:image\/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$/.test(image))throw Error('Choose a JPEG, PNG or WebP image.');
 return Response.json(await rpc('start',p));
 }
 if(action!=='advance')return Response.json(await rpc(action,p));
 const run:Run=await rpc('claim',p);if(run.status!=='running')return Response.json(run);
 const i=run.results.length,step=run.snapshot.steps[i],input=i?run.results[i-1].output:run.input.text,started=Date.now();let output='',error:string|undefined,tokens:number|undefined;
 try{
 const env=step.credential_env;if(!env||!['GEMINI_API_KEY','GOOGLE_API_KEY'].includes(env)||!process.env[env]||!step.model||!/^[\w.-]+$/.test(step.model))throw Error('Model credentials are unavailable.');
 const messages=stepMessages(step,input,run.created_at,run.input.text);
 if(messages.user.length>60000)throw Error('Prompt is too long. Shorten the instructions or reference data.');
 const parts:Record<string,unknown>[]=[{text:messages.user}];
 if(i===0&&run.input.image){const match=run.input.image.match(/^data:(image\/(?:png|jpeg|webp));base64,(.+)$/);if(!match)throw Error('Invalid image.');parts.push({inlineData:{mimeType:match[1],data:match[2]}});}
 const response=await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${step.model}:generateContent`,{method:'POST',headers:{'Content-Type':'application/json','x-goog-api-key':process.env[env]!},body:JSON.stringify({...(messages.system?{systemInstruction:{parts:[{text:messages.system}]}}:{}),contents:[{role:'user',parts}],generationConfig:{maxOutputTokens:4096,...(step.format==='json'?{responseMimeType:'application/json'}:{})}}),signal:AbortSignal.timeout(45000)});
 if(!response.ok)throw Error(response.status===429?'Model quota reached. Try again later.':`Model request failed (${response.status}).`);
 const body=await response.json();output=body.candidates?.[0]?.content?.parts?.map((v:{text?:string})=>v.text||'').join('')||'';tokens=body.usageMetadata?.totalTokenCount;
 if(!output)throw Error('The model returned no text.');if(step.format==='json')JSON.parse(output);
 }catch(e){error=e instanceof Error?e.message:'Generation failed.';}
 return Response.json(await rpc('finish',{id:run.id,claim:run.claim,result:{input,prompt:stepMessages(step,input,run.created_at,run.input.text).user,system:stepMessages(step,input,run.created_at,run.input.text).system,output,model:step.model,ms:Date.now()-started,tokens,error},error:error??null}));
 }catch(e){return Response.json({error:e instanceof Error?e.message:'Request failed.'},{status:400});}
}
