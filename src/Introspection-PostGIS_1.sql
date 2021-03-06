/*

  Database introspection niceties.

*/

begin;

/*

  Type for column information.

*/
drop type if exists gs__column cascade;

create type gs__column as(
  name varchar(250),
	type varchar(50),
	varchar_length integer,
  geomsrid varchar(50),
  geomgeometrytype varchar(50),
  geombbox geometry
);

/*

  Type for schema.table.column syntax.

*/
drop type if exists gs__oname cascade;

create type gs__oname as(
  oschema varchar(250),
  otable varchar(250),
  ocolumn varchar(250)
);

/*

  Gets a gs__o_name from a schema.table.column string.

*/
drop function if exists public.gs__oname(varchar);

create or replace function public.gs__oname(
  _name varchar(2000)
) returns gs__oname as
$$
  select (split_part($1, '.', 1),
          split_part($1, '.', 2),
          split_part($1, '.', 3))::gs__oname;
$$
language sql;

/*

  Returns info about a column in PostGIS 1.

*/
create or replace function public.gs__getcolumninfo(
  _column varchar(250)
) returns gs__column as
$$
declare
  _informationschema record;
  _sql text;
  _o gs__oname;
  _out gs__column;
  _srid varchar(40);
  _geometrytype varchar(100);
  _geombbox geometry;
  _nrow integer;
begin 
  _o = gs__oname(_column); 

  -- Get information in information_schema.columns.
  execute 'select udt_name, character_maximum_length
           from information_schema.columns
           where table_schema=$1 and
                 table_name=$2 and
                 column_name=$3;'
  using _o.oschema, _o.otable, _o.ocolumn
  into _informationschema;

  -- No column in information_schema.columns
  if _informationschema.udt_name is null and 
     _informationschema.character_maximum_length is null
  then
    return null;
  end if;

  if _informationschema.udt_name='geometry' then
    -- Check SRID uniformity
    _sql = 'select distinct st_srid(' || _o.ocolumn || ')::varchar as srid
            from ' || _o.oschema || '.' || _o.otable || ';';

    execute _sql into _srid;
    get diagnostics _nrow = ROW_COUNT;

    if _nrow>1 then
      _srid = 'ERR_Mixed';
    end if;

    -- Check geometrytype uniformity
    _sql = 'select distinct st_geometrytype(' || _o.ocolumn || ') as srid
            from ' || _o.oschema || '.' || _o.otable || ';';

    execute _sql into _geometrytype;
    get diagnostics _nrow = ROW_COUNT;

    if _nrow>1 then
      _geometrytype = 'ERR_Mixed';
    end if;

    -- Get bounding box
    if _srid<>'ERR_Mixed' then
      _sql = 'with c as(
                select st_collect(' || _o.ocolumn || ') as geom
                from ' || _o.oschema || '.' || _o.otable || '
              )
              select
                st_setsrid(gs__rectangle(gs__geom_boundaries(geom)),' || _srid::integer || ') as geom
              from c;';
      
      execute _sql into _geombbox;
      else
        _geombbox = null;
    end if;
  end if;

  _out = (_o.ocolumn, 
          _informationschema.udt_name, 
          _informationschema.character_maximum_length,
          _srid, _geometrytype, _geombbox)::gs__column;

  return _out;
end;
$$
language plpgsql;

/*

  Returns info about a column.

*/
create or replace function public.gs__get_column_info(
  _o_name gs__o_name
) returns gs__column as
$$
declare
  _s text;
  _out gs__column;
begin 
  _s = _o_name.o_schema || '.' || _o_name.o_table || '.' || _o_name.o_column;
  _out = gs__get_column_info(_s);
  
  return _out;
end;
$$
language plpgsql;

/*

  Returns info about a column.

*/
create or replace function public.gs__get_column_info(
  _o_schema varchar(250),
  _o_table varchar(250),
  _o_column varchar(250)
) returns gs__column as
$$
declare
  _s text;
  _out gs__column;
begin 
  _s = _o_schema || '.' || _o_table || '.' || _o_column;
  _out = gs__get_column_info(_s);
  
  return _out;
end;
$$
language plpgsql;

/*

  Returns the set of columns in a table.

*/
create or replace function public.gs__get_table_columns(
  _table varchar(250)
) returns gs__column[] as
$$
declare
  _o_name gs__o_name;
  _sql text;
  _r record;
  _out gs__column[];
begin
  _out = array[]::gs__column[];
  _o_name = gs__o_name(_table);

  _sql = 'select column_name
          from information_schema.columns
          where
            table_schema=$1 and
            table_name=$2
          order by ordinal_position';

  for _r in execute _sql using _o_name.o_schema, _o_name.o_table loop
    _out = _out ||
           gs__get_column_info((_o_name.o_schema, _o_name.o_table, _r.column_name)::gs__o_name);
  end loop;

  return _out;
end;
$$
language plpgsql;

commit;
