import {redirect} from 'next/navigation';
import {authClient} from '@/lib/supabase';
import Studio from './studio';
export default async function Page(){const db=await authClient();const {data:{user}}=await db.auth.getUser();if(!user)redirect('/login');const {data}=await db.rpc('week6_admin_me');if(!data?.authorized)return <main className="login"><h1>Admin access required</h1><form action="/auth/signout" method="post"><button>Sign out</button></form></main>;return <Studio name={data.name||'Administrator'}/>}
