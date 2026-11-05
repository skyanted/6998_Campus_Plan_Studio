begin;
alter table private.week7_steps add column context_selection jsonb;
alter table private.week7_app_rules add column rule_sections jsonb;
create function private.studio_reset_rule_sections() returns trigger language plpgsql set search_path='' as $$begin new.rule_sections:=null;return new;end$$;
create trigger studio_reset_rule_sections before update of template on private.week7_app_rules for each row execute function private.studio_reset_rule_sections();
revoke all on function private.studio_reset_rule_sections() from public,anon,authenticated;
-- Keep the existing shared template authoritative, with two selectable sections.
create function private.studio_rule_blocks() returns jsonb language sql stable security definer set search_path='' as $$
 with lines as (select line,ord,case when line ~ '^(Choose 1 to 3 tag|Select cover_id|Respond only as JSON)' then 'output' else 'activity' end kind from private.week7_app_rules,regexp_split_to_table(template,E'\n') with ordinality l(line,ord) where id=1)
 select coalesce((select rule_sections from private.week7_app_rules where id=1),jsonb_build_array(jsonb_build_object('id','activity','name','Activity rules','text',(select string_agg(replace(line,'Output starts_at as an ISO8601 timestamp including the America/New_York UTC offset.',''),E'\n' order by ord) from lines where kind='activity')),jsonb_build_object('id','output','name','Final output format','text',(select string_agg(line,E'\n' order by ord) from lines where kind='output')||E'\nOutput starts_at as an ISO8601 timestamp including the America/New_York UTC offset.')));
$$;
create function private.studio_library() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('rules',private.studio_rule_blocks(),'rules_revision',(select md5(to_jsonb(r)::text) from private.week7_app_rules r where id=1),'terms',(select coalesce(jsonb_agg(to_jsonb(t)||jsonb_build_object('revision',md5(to_jsonb(t)::text)) order by id),'[]') from private.week7_terms t),'examples',(select coalesce(jsonb_agg(to_jsonb(e)||jsonb_build_object('revision',md5(to_jsonb(e)::text)) order by id),'[]') from private.week7_examples e));
$$;
create function private.studio_validate_selection(sel jsonb) returns void language plpgsql security definer set search_path='' as $$begin
 if sel is null or sel='null'::jsonb then return;end if;
 if jsonb_typeof(sel)<>'object' or jsonb_typeof(sel->'rules') is distinct from 'array' or jsonb_typeof(sel->'terms') is distinct from 'array' or jsonb_typeof(sel->'examples') is distinct from 'array' or jsonb_array_length(sel->'terms')>30 or jsonb_array_length(sel->'examples')>5 then raise exception 'Select up to 30 terms and 5 examples.';end if;
 if exists(select 1 from jsonb_array_elements_text(sel->'rules') x where x not in ('activity','output')) or exists(select 1 from jsonb_array_elements_text(sel->'terms') x where not exists(select 1 from private.week7_terms where id::text=x)) or exists(select 1 from jsonb_array_elements_text(sel->'examples') x where not exists(select 1 from private.week7_examples where id::text=x)) then raise exception 'A selected item was removed. Refresh the library.';end if;
end$$;
create function private.studio_step_context(st private.week7_steps) returns jsonb language plpgsql stable security definer set search_path='' as $$declare sel jsonb:=st.context_selection;begin
 if sel is null or sel='null'::jsonb then return case when st.use_app_context then private.studio_context() else null end;end if;
 return jsonb_build_object('source','Shared','rules',coalesce((select string_agg(x->>'text',E'\n') from jsonb_array_elements(private.studio_rule_blocks()) x where sel->'rules' ? (x->>'id')),''),'rule_blocks',(select coalesce(jsonb_agg(x),'[]') from jsonb_array_elements(private.studio_rule_blocks()) x where sel->'rules' ? (x->>'id')),'terms',(select coalesce(jsonb_agg(jsonb_build_object('id',t.id,'term',t.term,'definition',t.definition) order by t.id),'[]') from private.week7_terms t where t.enabled and sel->'terms' @> jsonb_build_array(t.id)),'examples',(select coalesce(jsonb_agg(jsonb_build_object('id',e.id,'title',e.title,'input',e.input,'output',e.output) order by e.id),'[]') from private.week7_examples e where e.enabled and sel->'examples' @> jsonb_build_array(e.id)),'covers',private.studio_context()->'covers');
end$$;
create function private.studio_library_save(p jsonb) returns jsonb language plpgsql security definer set search_path='' as $$declare blocks jsonb;tpl text;begin
 perform private.week6_assert_superadmin();
 if p->>'section'='rules' then
 perform pg_advisory_xact_lock(729100);
 blocks:=private.studio_rule_blocks();
 if p->>'id' not in ('activity','output') or length(btrim(p->>'text')) not between 1 and 8000 then raise exception 'Enter valid rules.';end if;
 -- The output section stays recognizable for older Admin template editors.
 if p->>'id'='output' and (position('Respond only as JSON' in (p->>'text'))=0 or position('{{tag_slugs}}' in (p->>'text'))=0 or position('{{cover_catalog}}' in (p->>'text'))=0) then raise exception 'Keep the JSON format, tag slugs and cover catalog.';end if;
 select string_agg(case when x->>'id'=p->>'id' then p->>'text' else x->>'text' end,E'\n') into tpl from jsonb_array_elements(blocks) x;
 perform private.week7_admin_set_app_rules(tpl,p->>'revision');
 update private.week7_app_rules set rule_sections=(select jsonb_agg(case when x->>'id'=p->>'id' then x||jsonb_build_object('text',p->>'text') else x end) from jsonb_array_elements(blocks) x) where id=1;
 elsif p->>'section' in ('terms','examples') then
 perform private.week7_admin_save(p->>'section',p->>'action',nullif(p->>'id','')::bigint,p->'payload',coalesce(p->>'revision',''));
 else raise exception 'Invalid library section.';end if;
 return private.studio_library();
end$$;
create or replace function private.studio_snapshot(cid bigint) returns jsonb language plpgsql stable security definer set search_path='' as $$declare result jsonb;begin
 select jsonb_agg(to_jsonb(st)||jsonb_build_object('model_id',m.id,'model',m.identifier,'adapter',v.adapter,'provider',v.name,'credential_env',v.credential_env,'assembly',private.studio_step_context(st)) order by st.position) into result from private.week7_steps st join private.week7_models m on m.id=coalesce(st.model_id,(select model_id from private.week7_generation_settings where id=1)) join private.week7_providers v on v.id=m.provider_id where st.chain_id=cid and m.enabled and v.enabled and v.adapter='gemini';
 if result is null or jsonb_array_length(result)<>(select count(*) from private.week7_steps where chain_id=cid) then raise exception 'Add steps and select enabled models.';end if;return result;
end$$;
create or replace function public.studio_command(action text,p jsonb default '{}') returns jsonb language plpgsql security definer set search_path='' as $$
declare c private.week7_chains;r private.studio_runs;s jsonb;steps jsonb;idx integer:=0;sid bigint;seen bigint[]:='{}';
begin
perform private.week6_assert_superadmin();
if action='library-save' then
 return private.studio_library_save(p);
elsif action='list' then
 return jsonb_build_object('chains',(select coalesce(jsonb_agg(to_jsonb(x) order by x.id desc),'[]') from (select cl.*,private.studio_revision(cl.id) revision,(select weight from private.week7_mix where chain_id=cl.id) weight,(select coalesce(jsonb_agg(to_jsonb(st)||jsonb_build_object('assembly',private.studio_step_context(st)) order by st.position),'[]') from private.week7_steps st where st.chain_id=cl.id) steps from private.week7_chains cl)x),'models',(select coalesce(jsonb_agg(jsonb_build_object('id',m.id,'name',m.name,'identifier',m.identifier)),'[]') from private.week7_models m join private.week7_providers v on v.id=m.provider_id where m.enabled and v.enabled and v.adapter='gemini'),'context',private.studio_context(),'library',private.studio_library());
elsif action='save' then
 perform pg_advisory_xact_lock(729100);
 if length(btrim(coalesce(p->>'name',''))) not between 1 and 100 or length(coalesce(p->>'description',''))>1000 or jsonb_typeof(p->'steps') is distinct from 'array' or jsonb_array_length(p->'steps')>10 then raise exception 'Check the chain name and steps (maximum 10).';end if;
 if p->>'id' is null then insert into private.week7_chains(name,description) values(btrim(p->>'name'),coalesce(p->>'description','')) returning * into c;insert into private.week7_mix(chain_id,weight) values(c.id,0);
 else select * into c from private.week7_chains where id=(p->>'id')::bigint for update;
 if c.id is null or private.studio_revision(c.id) is distinct from p->>'revision' then raise exception 'Chain changed. Reload before saving.';end if;
 if exists(select 1 from private.week7_mix where chain_id=c.id and weight>0) and (jsonb_array_length(p->'steps')=0 or p->'steps'->-1->>'format' is distinct from 'json' or p->'steps'->-1->>'use_app_context' is distinct from 'true') then raise exception 'Active Campus Plans chains must end with JSON and App context enabled.';end if;
 update private.week7_chains set name=btrim(p->>'name'),description=coalesce(p->>'description','') where id=c.id;
 end if;
 update private.week7_steps set position=position+100000 where chain_id=c.id;
 for s in select value from jsonb_array_elements(p->'steps') loop
 idx:=idx+1;
 perform private.studio_validate_selection(s->'context_selection');
 if length(btrim(coalesce(s->>'name',''))) not between 1 and 100 or length(btrim(coalesce(s->>'instructions',''))) not between 1 and 10000 or coalesce(s->>'format','') not in ('text','json') then raise exception 'Each step needs a name, prompt and output format.';end if;
 if nullif(s->>'model_id','') is not null and not exists(select 1 from private.week7_models m join private.week7_providers v on v.id=m.provider_id where m.id=(s->>'model_id')::bigint and m.enabled and v.enabled and v.adapter='gemini') then raise exception 'Select an enabled model.';end if;
 sid:=nullif(s->>'id','')::bigint;
 if sid is not null then
 if sid=any(seen) or not exists(select 1 from private.week7_steps where id=sid and chain_id=c.id) then raise exception 'Step no longer belongs to this chain.';end if;
 update private.week7_steps set position=idx,name=btrim(s->>'name'),instructions=btrim(s->>'instructions'),model_id=nullif(s->>'model_id','')::bigint,format=s->>'format',use_app_context=coalesce((s->>'use_app_context')::boolean,false)  ,context_selection=nullif(s->'context_selection','null'::jsonb) where id=sid;
 else insert into private.week7_steps(chain_id,position,name,instructions,model_id,format,use_app_context,context_selection) values(c.id,idx,btrim(s->>'name'),btrim(s->>'instructions'),nullif(s->>'model_id','')::bigint,s->>'format',coalesce((s->>'use_app_context')::boolean,false),nullif(s->'context_selection','null'::jsonb)) returning id into sid;end if;
 seen:=array_append(seen,sid);
 end loop;
 delete from private.week7_steps where chain_id=c.id and not(id=any(seen));
 if exists(select 1 from private.week7_mix where chain_id=c.id and weight>0) and exists(select 1 from private.week7_steps st where st.chain_id=c.id and st.position=idx and st.context_selection is not null and not coalesce(st.context_selection->'rules' ? 'output',false)) then raise exception 'The last step of an active chain needs Final output format.';end if;
 return jsonb_build_object('id',c.id,'revision',private.studio_revision(c.id));
elsif action='delete' then
 perform pg_advisory_xact_lock(729100);select * into c from private.week7_chains where id=(p->>'id')::bigint for update;
 if c.id is null or private.studio_revision(c.id) is distinct from p->>'revision' then raise exception 'Chain changed. Reload before deleting.';end if;
 if exists(select 1 from private.week7_mix where chain_id=c.id and weight>0) then raise exception 'Remove this chain from the active mix in Admin before deleting it.';end if;
 delete from private.week7_mix where chain_id=c.id;delete from private.week7_steps where chain_id=c.id;delete from private.week7_chains where id=c.id;return '{}';
elsif action='runs' then
 return (select coalesce(jsonb_agg(to_jsonb(rr) order by rr.created_at desc),'[]') from (select id,shared_chain_id,snapshot->>'name' name,status,created_at,error,jsonb_array_length(results) completed_steps from private.studio_runs where shared_chain_id=(p->>'id')::bigint order by created_at desc limit 50)rr);
elsif action='run' then
 select * into r from private.studio_runs where id=(p->>'id')::uuid;if r.id is null then raise exception 'Run not found.';end if;return to_jsonb(r);
elsif action='start' then
 perform pg_advisory_xact_lock(729100);select * into c from private.week7_chains where id=(p->>'id')::bigint for share;
 if c.id is null or private.studio_revision(c.id) is distinct from p->>'revision' then raise exception 'Chain changed. Reload before running.';end if;
 if length(coalesce(p->'input'->>'text',''))>12000 or length(coalesce(p->'input'->>'image',''))>2900000 or (coalesce(p->'input'->>'text','')='' and coalesce(p->'input'->>'image','')='') then raise exception 'Enter text or upload an image.';end if;
 steps:=private.studio_snapshot(c.id);
 insert into private.studio_runs(shared_chain_id,created_by,snapshot,input) values(c.id,auth.uid(),to_jsonb(c)||jsonb_build_object('steps',steps),p->'input') returning * into r;return to_jsonb(r);
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


revoke all on function private.studio_rule_blocks(),private.studio_library(),private.studio_validate_selection(jsonb),private.studio_step_context(private.week7_steps),private.studio_library_save(jsonb) from public,anon,authenticated;
create or replace function private.week8_validate_mix() returns trigger language plpgsql security definer set search_path='' as $$declare last_step private.week7_steps;begin
 if new.weight>0 then
 select * into last_step from private.week7_steps where chain_id=new.chain_id order by position desc limit 1;
 if last_step.id is null or last_step.format<>'json' or not last_step.use_app_context or (last_step.context_selection is not null and not coalesce(last_step.context_selection->'rules' ? 'output',false)) then raise exception 'The final step needs JSON and Final output format before using this chain.';end if;
 end if;return new;
end$$;
notify pgrst,'reload schema';
commit;
