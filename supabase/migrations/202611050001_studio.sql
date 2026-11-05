begin;
create table private.studio_chains(id uuid primary key default gen_random_uuid(),name text not null check(length(btrim(name)) between 1 and 100),description text not null default '',revision integer not null default 1,created_at timestamptz not null default now());
create table private.studio_steps(id uuid primary key default gen_random_uuid(),chain_id uuid not null references private.studio_chains on delete cascade,position integer not null check(position>0),name text not null,instructions text not null,model_id bigint references private.week7_models,format text not null check(format in ('text','json')),unique(chain_id,position));
create table private.studio_runs(id uuid primary key default gen_random_uuid(),chain_id uuid references private.studio_chains on delete set null,created_by uuid not null references auth.users,snapshot jsonb not null,input jsonb not null,results jsonb not null default '[]',status text not null default 'ready' check(status in ('ready','running','completed','failed')),claim uuid,started_at timestamptz,created_at timestamptz not null default now(),error text);
alter table private.studio_chains enable row level security;
alter table private.studio_steps enable row level security;
alter table private.studio_runs enable row level security;
revoke all on private.studio_chains,private.studio_steps,private.studio_runs from public,anon,authenticated;
create function public.studio_command(action text,p jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare c private.studio_chains;r private.studio_runs;s jsonb;steps jsonb;models jsonb;idx integer:=0;token uuid;
begin
perform private.week6_assert_superadmin();
if action='list' then
 return jsonb_build_object('chains',(select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]') from (select cl.*,(select coalesce(jsonb_agg(to_jsonb(st) order by st.position),'[]') from private.studio_steps st where st.chain_id=cl.id) steps from private.studio_chains cl)x),'models',(select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'name',m.name,'identifier',m.identifier)),'[]') from private.week7_models m join private.week7_providers v on v.id=m.provider_id where m.enabled and v.enabled and v.adapter='gemini'));
elsif action='save' then
 perform pg_advisory_xact_lock(830100);
 if length(btrim(coalesce(p->>'name',''))) not between 1 and 100 or length(coalesce(p->>'description',''))>1000 or jsonb_typeof(p->'steps') is distinct from 'array' or jsonb_array_length(p->'steps')>10 then raise exception 'Check the chain name and steps (maximum 10).';end if;
 if p->>'id' is null then insert into private.studio_chains(name,description) values(btrim(p->>'name'),coalesce(p->>'description','')) returning * into c;
 else select * into c from private.studio_chains where id=(p->>'id')::uuid for update;if c.id is null or c.revision is distinct from (p->>'revision')::integer then raise exception 'Chain changed. Reload before saving.';end if;update private.studio_chains set name=btrim(p->>'name'),description=coalesce(p->>'description',''),revision=revision+1 where id=c.id returning * into c;delete from private.studio_steps where chain_id=c.id;end if;
 for s in select value from jsonb_array_elements(p->'steps') loop
 idx:=idx+1;
 if length(btrim(coalesce(s->>'name',''))) not between 1 and 100 or length(btrim(coalesce(s->>'instructions',''))) not between 1 and 10000 or coalesce(s->>'format','') not in ('text','json') then raise exception 'Each step needs a name, prompt and output format.';end if;
 if nullif(s->>'model_id','') is not null and not exists(select 1 from private.week7_models m join private.week7_providers v on v.id=m.provider_id where m.id=(s->>'model_id')::bigint and m.enabled and v.enabled and v.adapter='gemini') then raise exception 'Select an enabled model.';end if;
 insert into private.studio_steps(chain_id,position,name,instructions,model_id,format) values(c.id,idx,btrim(s->>'name'),btrim(s->>'instructions'),nullif(s->>'model_id','')::bigint,s->>'format');end loop;
 return to_jsonb(c);
elsif action='delete' then
 delete from private.studio_chains where id=(p->>'id')::uuid and revision=(p->>'revision')::integer;if not found then raise exception 'Chain changed. Reload before deleting.';end if;return '{}';
elsif action='runs' then
 return (select coalesce(jsonb_agg(to_jsonb(rr) order by rr.created_at desc),'[]') from (select id,chain_id,snapshot->>'name' name,status,created_at,error,jsonb_array_length(results) completed_steps from private.studio_runs where chain_id=(p->>'id')::uuid order by created_at desc limit 50)rr);
elsif action='run' then
 select * into r from private.studio_runs where id=(p->>'id')::uuid;if r.id is null then raise exception 'Run not found.';end if;return to_jsonb(r);
elsif action='start' then
 select * into c from private.studio_chains where id=(p->>'id')::uuid for share;
 if c.id is null or c.revision is distinct from (p->>'revision')::integer then raise exception 'Chain changed. Reload before running.';end if;
 if length(coalesce(p->'input'->>'text',''))>12000 or length(coalesce(p->'input'->>'image',''))>2900000 or (coalesce(p->'input'->>'text','')='' and coalesce(p->'input'->>'image','')='') then raise exception 'Enter text or upload an image.';end if;
 select jsonb_agg(to_jsonb(st)||jsonb_build_object('model',m.identifier,'credential_env',v.credential_env) order by st.position) into steps from private.studio_steps st join private.week7_models m on m.id=coalesce(st.model_id,(p->>'default_model_id')::bigint) join private.week7_providers v on v.id=m.provider_id where st.chain_id=c.id and m.enabled and v.enabled and v.adapter='gemini';
 if steps is null or jsonb_array_length(steps)<>(select count(*) from private.studio_steps where chain_id=c.id) then raise exception 'Add steps and select enabled models.';end if;
 insert into private.studio_runs(chain_id,created_by,snapshot,input) values(c.id,auth.uid(),to_jsonb(c)||jsonb_build_object('steps',steps),p->'input') returning * into r;return to_jsonb(r);
elsif action='claim' then
 select * into r from private.studio_runs where id=(p->>'id')::uuid for update;
 if r.status='running' and r.started_at<now()-interval '2 minutes' then update private.studio_runs set status='failed',error='Execution interrupted. Start a new run.' where id=r.id returning * into r;return to_jsonb(r);end if;
 if r.id is null or r.status<>'ready' then raise exception 'Run is not ready.';end if;
 update private.studio_runs set status='running',claim=gen_random_uuid(),started_at=now() where id=r.id returning * into r;return to_jsonb(r);
elsif action='finish' then
 select * into r from private.studio_runs where id=(p->>'id')::uuid for update;
 if r.id is null or r.status<>'running' or r.claim is distinct from (p->>'claim')::uuid then raise exception 'Execution no longer matches.';end if;
 update private.studio_runs set results=results||jsonb_build_array(p->'result'),status=case when p->>'error' is not null then 'failed' when jsonb_array_length(results)+1=jsonb_array_length(snapshot->'steps') then 'completed' else 'ready' end,error=left(p->>'error',1000),claim=null where id=r.id returning * into r;return to_jsonb(r);
end if;
raise exception 'Unknown action.';
end$$;
revoke all on function public.studio_command(text,jsonb) from public,anon;
grant execute on function public.studio_command(text,jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
