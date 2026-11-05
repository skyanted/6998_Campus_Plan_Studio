import 'server-only';
import {createServerClient} from '@supabase/ssr';
import {cookies} from 'next/headers';
export async function authClient(){
 const jar=await cookies();
 return createServerClient(process.env.NEXT_PUBLIC_SUPABASE_URL!,process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,{
  db:{schema:'public'},cookieOptions:{name:'campus-studio-auth'},
  cookies:{getAll:()=>jar.getAll(),setAll(values){
   try{values.forEach(({name,value,options})=>jar.set(name,value,options));}
   catch{/* Proxy refreshes cookies for server components. */}
  }}
 });
}
